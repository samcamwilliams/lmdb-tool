-module(lmdb_tool).

-export([main/1]).

-define(EXIT_OK, 0).
-define(EXIT_ERROR, 1).

-define(DEFAULT_BATCH_SIZE, 1000).
-define(DEFAULT_MAP_SIZE_BYTES, 1099511627776). % 1 TB

main(Args) ->
    case ensure_elmdb_loaded() of
        ok ->
            case run(Args) of
                ok ->
                    halt(?EXIT_OK);
                {error, usage, Message} ->
                    io:format(standard_error, "~s~n~n", [Message]),
                    print_usage(),
                    halt(?EXIT_ERROR);
                {error, Message} ->
                    io:format(standard_error, "~s~n", [Message]),
                    halt(?EXIT_ERROR)
            end;
        {error, Message} ->
            io:format(standard_error, "~s~n", [Message]),
            halt(?EXIT_ERROR)
    end.

run(Args) ->
    case parse_args(Args) of
        {ok, {merge, FromPath, ToPath}} ->
            merge_databases(FromPath, ToPath);
        {ok, {print, DbPath, Prefix}} ->
            print_database(DbPath, Prefix);
        {error, Message} ->
            {error, usage, Message}
    end.

parse_args(["--merge" | Rest]) ->
    parse_merge_args(Rest, #{});
parse_args(["--print", DbPath]) ->
    {ok, {print, DbPath, undefined}};
parse_args(["--print", DbPath, Prefix]) ->
    {ok, {print, DbPath, Prefix}};
parse_args(["--print" | _]) ->
    {error, "Invalid --print arguments"};
parse_args(_) ->
    {error, "Invalid arguments"}.

parse_merge_args([], Opts) ->
    case {maps:get(from, Opts, undefined), maps:get(to, Opts, undefined)} of
        {undefined, _} ->
            {error, "Missing required option --from"};
        {_, undefined} ->
            {error, "Missing required option --to"};
        {FromPath, ToPath} ->
            {ok, {merge, FromPath, ToPath}}
    end;
parse_merge_args(["--from", Value | Rest], Opts) ->
    parse_merge_args(Rest, Opts#{from => Value});
parse_merge_args(["--to", Value | Rest], Opts) ->
    parse_merge_args(Rest, Opts#{to => Value});
parse_merge_args([Unknown | _], _Opts) ->
    {error, io_lib:format("Unknown merge option: ~s", [Unknown])}.

merge_databases(FromPath, ToPath) ->
    case same_path(FromPath, ToPath) of
        true ->
            {error, "Source and destination paths must be different"};
        false ->
            with_database(FromPath, source, fun(_SourceEnv, SourceDB) ->
                with_database(ToPath, target, fun(_TargetEnv, TargetDB) ->
                    merge_stream(SourceDB, TargetDB)
                end)
            end)
    end.

merge_stream(SourceDB, TargetDB) ->
    BatchSize = batch_size(),
    case elmdb:iterator(SourceDB) of
        {error, Type, Description} ->
            {error, format_elmdb_error("Failed to create source iterator", Type, Description)};
        Cursor ->
            merge_loop(SourceDB, Cursor, TargetDB, [], 0, BatchSize, 0)
    end.

merge_loop(SourceDB, Cursor, TargetDB, Batch, BatchCount, BatchSize, WrittenCount) ->
    case elmdb:iterator_next(SourceDB, Cursor) of
        {ok, Key, Value, NextCursor} ->
            NextBatch = [{Key, Value} | Batch],
            NextBatchCount = BatchCount + 1,
            case NextBatchCount >= BatchSize of
                true ->
                    case write_batch(TargetDB, lists:reverse(NextBatch), NextBatchCount, WrittenCount) of
                        {ok, NextWrittenCount} ->
                            merge_loop(SourceDB, NextCursor, TargetDB, [], 0, BatchSize, NextWrittenCount);
                        {error, _} = Error ->
                            Error
                    end;
                false ->
                    merge_loop(SourceDB, NextCursor, TargetDB, NextBatch, NextBatchCount, BatchSize, WrittenCount)
            end;
        undefined ->
            case flush_remaining_batch(TargetDB, Batch, BatchCount, WrittenCount) of
                {ok, _FinalWrittenCount} ->
                    case elmdb:flush(TargetDB) of
                        ok -> ok;
                        {error, Type, Description} ->
                            {error, format_elmdb_error("Failed to flush destination database", Type, Description)};
                        Other ->
                            {error, io_lib:format("Unexpected flush response: ~p", [Other])}
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, Type, Description} ->
            {error, format_elmdb_error("Source iterator failed", Type, Description)};
        Other ->
            {error, io_lib:format("Unexpected iterator response: ~p", [Other])}
    end.

write_batch(_TargetDB, [], 0, WrittenCount) ->
    {ok, WrittenCount};
write_batch(TargetDB, Batch, BatchCount, WrittenCount) ->
    case elmdb:put_batch(TargetDB, Batch) of
        ok ->
            {ok, WrittenCount + BatchCount};
        {ok, SuccessCount, Errors} ->
            {error,
             io_lib:format(
               "Destination batch write had partial failures (success_count=~B, errors=~p)",
               [SuccessCount, Errors]
              )};
        {error, Type, Description} ->
            {error, format_elmdb_error("Destination batch write failed", Type, Description)};
        Other ->
            {error, io_lib:format("Unexpected put_batch response: ~p", [Other])}
    end.

flush_remaining_batch(_TargetDB, [], 0, WrittenCount) ->
    {ok, WrittenCount};
flush_remaining_batch(TargetDB, Batch, BatchCount, WrittenCount) ->
    write_batch(TargetDB, lists:reverse(Batch), BatchCount, WrittenCount).

print_database(DbPath, Prefix) ->
    with_database(DbPath, source, fun(_Env, DB) ->
        print_stream(DB, Prefix)
    end).

print_stream(DB, undefined) ->
    case elmdb:iterator(DB) of
        {error, Type, Description} ->
            {error, format_elmdb_error("Failed to create iterator", Type, Description)};
        Cursor ->
            print_loop(DB, Cursor)
    end;
print_stream(DB, Prefix) ->
    PrefixBin = unicode:characters_to_binary(Prefix),
    case elmdb:get(DB, PrefixBin) of
        {ok, Value} ->
            print_line(PrefixBin, Value),
            print_loop(DB, {iterator, PrefixBin});
        not_found ->
            print_loop(DB, {iterator, PrefixBin});
        {error, Type, Description} ->
            {error, format_elmdb_error("Failed to position print cursor", Type, Description)};
        Other ->
            {error, io_lib:format("Unexpected get response: ~p", [Other])}
    end.

print_loop(DB, Cursor) ->
    case elmdb:iterator_next(DB, Cursor) of
        {ok, Key, Value, NextCursor} ->
            print_line(Key, Value),
            print_loop(DB, NextCursor);
        undefined ->
            ok;
        {error, Type, Description} ->
            {error, format_elmdb_error("Iterator failed", Type, Description)};
        Other ->
            {error, io_lib:format("Unexpected iterator response: ~p", [Other])}
    end.

print_line(Key, Value) ->
    io:format("~s: ~s~n", [display_binary(Key), display_binary(Value)]).

display_binary(Binary) ->
    case is_printable_ascii(Binary) of
        true ->
            binary_to_list(Binary);
        false ->
            "0x" ++ string:lowercase(binary_to_list(binary:encode_hex(Binary)))
    end.

is_printable_ascii(Binary) ->
    lists:all(
      fun(Codepoint) ->
          Codepoint >= 32 andalso Codepoint =< 126
      end,
      binary:bin_to_list(Binary)
     ).

with_database(Path, Mode, Fun) ->
    case prepare_path(Path, Mode) of
        ok ->
            open_database(Path, Mode, Fun);
        {error, _} = Error ->
            Error
    end.

open_database(Path, Mode, Fun) ->
    case elmdb:env_open(Path, env_options(Mode)) of
        {ok, Env} ->
            case elmdb:db_open(Env, db_options(Mode)) of
                {ok, DB} ->
                    try
                        Fun(Env, DB)
                    after
                        safe_close_database(Env, DB)
                    end;
                {error, Reason} ->
                    _ = safe_close_environment(Env),
                    {error, io_lib:format("Failed to open database at ~s: ~p", [Path, Reason])};
                Other ->
                    _ = safe_close_environment(Env),
                    {error, io_lib:format("Unexpected db_open response at ~s: ~p", [Path, Other])}
            end;
        {error, Reason} ->
            {error, io_lib:format("Failed to open LMDB environment at ~s: ~p", [Path, Reason])};
        Other ->
            {error, io_lib:format("Unexpected env_open response at ~s: ~p", [Path, Other])}
    end.

prepare_path(Path, source) ->
    case filelib:is_dir(Path) of
        true ->
            ok;
        false ->
            {error, io_lib:format("Database path is not an existing directory: ~s", [Path])}
    end;
prepare_path(Path, target) ->
    case filelib:is_dir(Path) of
        true ->
            ok;
        false ->
            DataMdbPath = filename:join(Path, "data.mdb"),
            case filelib:ensure_dir(DataMdbPath) of
                ok ->
                    ok;
                {error, Reason} ->
                    {error, io_lib:format("Failed to create destination directory (~s): ~p", [Path, Reason])}
            end
    end.

env_options(source) ->
    [];
env_options(target) ->
    [{map_size, map_size_bytes()}].

db_options(source) ->
    [];
db_options(target) ->
    [create].

batch_size() ->
    case parse_positive_integer_env("LMDB_TOOL_BATCH_SIZE") of
        undefined -> ?DEFAULT_BATCH_SIZE;
        Value -> Value
    end.

map_size_bytes() ->
    case parse_positive_integer_env("LMDB_TOOL_MAP_SIZE_BYTES") of
        undefined -> ?DEFAULT_MAP_SIZE_BYTES;
        Value -> Value
    end.

parse_positive_integer_env(Name) ->
    case os:getenv(Name) of
        false ->
            undefined;
        Raw ->
            case string:to_integer(Raw) of
                {IntValue, ""} when IntValue > 0 ->
                    IntValue;
                _ ->
                    undefined
            end
    end.

safe_close_database(Env, DB) ->
    _ = safe_close_db(DB),
    _ = safe_close_environment(Env),
    ok.

safe_close_db(DB) ->
    case catch elmdb:db_close(DB) of
        ok -> ok;
        _ -> ok
    end.

safe_close_environment(Env) ->
    case catch elmdb:env_close(Env) of
        ok -> ok;
        _ -> ok
    end.

same_path(PathA, PathB) ->
    filename:absname(PathA) =:= filename:absname(PathB).

format_elmdb_error(Prefix, Type, Description) ->
    io_lib:format("~s (~p): ~s", [Prefix, Type, description_to_text(Description)]).

description_to_text(Description) when is_binary(Description) ->
    binary_to_list(Description);
description_to_text(Description) when is_list(Description) ->
    Description;
description_to_text(Description) ->
    io_lib:format("~p", [Description]).

ensure_elmdb_loaded() ->
    add_elmdb_code_path(),
    case code:ensure_loaded(elmdb) of
        {module, elmdb} ->
            ok;
        {error, on_load_failure} ->
            {error, "Failed to load elmdb NIF. Ensure dependency build completed with priv/elmdb_nif.so present."};
        {error, Reason} ->
            {error, io_lib:format("Failed to load elmdb module: ~p", [Reason])}
    end.

add_elmdb_code_path() ->
    ScriptPath = escript:script_name(),
    ScriptDir = filename:dirname(ScriptPath),
    Candidate = filename:absname(filename:join([ScriptDir, "..", "lib", "elmdb", "ebin"])),
    case filelib:is_dir(Candidate) of
        true ->
            code:add_patha(Candidate),
            ok;
        false ->
            ok
    end.

print_usage() ->
    io:format(
      standard_error,
      "Usage:~n"
      "  lmdb-tool --merge --from DB1Location --to DB2Location~n"
      "  lmdb-tool --print DBLocation [Prefix]~n~n"
      "Modes:~n"
      "  --merge  Copy all key/value pairs from DB1Location to DB2Location.~n"
      "           Streaming cursor scan + chunked writes (bounded memory).~n"
      "  --print  Print key/value pairs as \"Key: Value\" lines.~n"
      "           If Prefix is set, starts from that key position onward.~n~n"
      "Environment Variables:~n"
      "  LMDB_TOOL_BATCH_SIZE       Batch size for merge writes (default 1000).~n"
      "  LMDB_TOOL_MAP_SIZE_BYTES   Destination map size in bytes (default 1 TB).~n",
      []
     ).

# lmdb-tool

Simple LMDB command-line utility built as an Erlang `rebar3` escript using
[`elmdb-rs`](https://github.com/permaweb/elmdb-rs).

## Build

```bash
rebar3 escriptize
```

Output binary:

```bash
./_build/default/bin/lmdb-tool
```

## Install

```bash
make install
```

This installs:
- Launcher: `~/.local/bin/lmdb-tool`
- Runtime bundle: `~/.local/lib/lmdb-tool`

Custom install prefix:

```bash
make install PREFIX=/usr/local
```

Uninstall:

```bash
make uninstall
```

## Usage

```bash
lmdb-tool --merge --from DB1Location [--from DB2Location ...] --to DBLocation
lmdb-tool --print DBLocation [Prefix]
```

### Modes

- `--merge --from DB1Location [--from DB2Location ...] --to DBLocation`
  - Streams records from one or more sources to one destination using
    `elmdb:iterator/1` and `elmdb:iterator_next/2`.
  - Writes in bounded-size chunks with `elmdb:put_batch/2`.
  - Does not hold the full dataset in memory.
- `--print DBLocation [Prefix]`
  - Streams and prints one key/value per line as `Key: Value`.
  - If `Prefix` is provided, starts from that key position onward.

## Environment Variables

- `LMDB_TOOL_BATCH_SIZE` (default `1000`)
  - Number of key/value pairs per destination write batch during `--merge`.
- `LMDB_TOOL_MAP_SIZE_BYTES` (default `1099511627776`, 1 TB)
  - Map size used when opening destination environments.

## Notes

- Database paths are expected to be LMDB directories.
- Non-printable binary keys/values are printed as `0x...` hex.

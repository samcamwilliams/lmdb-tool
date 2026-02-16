SHELL := /bin/sh

REBAR3 ?= rebar3

BUILD_DIR := _build/default
ESCRIPT := $(BUILD_DIR)/bin/lmdb-tool
ELMDB_EBIN := $(BUILD_DIR)/lib/elmdb/ebin
ELMDB_PRIV := $(BUILD_DIR)/lib/elmdb/priv

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
INSTALL_ROOT ?= $(PREFIX)/lib/lmdb-tool

INSTALL_BIN := $(INSTALL_ROOT)/bin/lmdb-tool
INSTALL_LIB := $(INSTALL_ROOT)/lib/elmdb
GLOBAL_BIN := $(BINDIR)/lmdb-tool

.PHONY: build install uninstall clean

build:
	$(REBAR3) escriptize

install: build
	test -d "$(ELMDB_EBIN)"
	test -d "$(ELMDB_PRIV)"
	rm -rf "$(INSTALL_ROOT)"
	mkdir -p "$(INSTALL_ROOT)/bin" "$(INSTALL_LIB)" "$(BINDIR)"
	cp "$(ESCRIPT)" "$(INSTALL_BIN)"
	cp -R "$(ELMDB_EBIN)" "$(INSTALL_LIB)/"
	cp -R "$(ELMDB_PRIV)" "$(INSTALL_LIB)/"
	chmod +x "$(INSTALL_BIN)"
	printf '%s\n' '#!/usr/bin/env sh' 'exec "$(INSTALL_BIN)" "$$@"' > "$(GLOBAL_BIN)"
	chmod +x "$(GLOBAL_BIN)"
	@echo "Installed: $(GLOBAL_BIN)"
	@echo "If needed, add to PATH: export PATH=\"$(BINDIR):\$$PATH\""

uninstall:
	rm -f "$(GLOBAL_BIN)"
	rm -rf "$(INSTALL_ROOT)"
	@echo "Uninstalled lmdb-tool from $(PREFIX)"

clean:
	$(REBAR3) clean

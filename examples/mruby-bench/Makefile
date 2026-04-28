# Makefile for the mruby-bench WASI fixture.
#
# Builds a single .wasm by cross-compiling mruby with the wasi-sdk
# clang toolchain, precompiling bench.rb with mrbc into bench.c, and
# linking main.c against libmruby.a.
#
# Prerequisites
#   * wasi-sdk (https://github.com/WebAssembly/wasi-sdk) installed; set
#     WASI_SDK_PATH to its root (containing bin/, share/wasi-sysroot/).
#   * Ruby + Rake (used by mruby's own build system to run mrbc).
#   * git (for the mruby clone step).
#
# Output: build/mruby_bench.wasm
#
# Usage:
#   export WASI_SDK_PATH=/opt/wasi-sdk
#   make           # build everything
#   make clean     # remove build/ but keep vendor/
#   make distclean # remove build/ and vendor/

MRUBY_TAG := 3.3.0
MRUBY_SRC := vendor/mruby
BUILD_DIR := build
WASM_OUT  := $(BUILD_DIR)/mruby_bench.wasm

CONFIG    := $(abspath build_config.rb)

ifndef WASI_SDK_PATH
$(error WASI_SDK_PATH must point to your wasi-sdk install root)
endif

CLANG     := $(WASI_SDK_PATH)/bin/clang
SYSROOT   := $(WASI_SDK_PATH)/share/wasi-sysroot

CFLAGS    := --target=wasm32-wasi --sysroot=$(SYSROOT) -O2 \
             -I$(MRUBY_SRC)/include
LDFLAGS   := --target=wasm32-wasi --sysroot=$(SYSROOT) \
             -Wl,--allow-undefined-file=$(SYSROOT)/share/wasm32-wasi/undefined-symbols.txt
LIBS      := $(MRUBY_SRC)/build/wasm32-wasi/lib/libmruby.a

.PHONY: all clean distclean mruby

all: $(WASM_OUT)

# 1) Vendor mruby at a pinned tag.
$(MRUBY_SRC):
	git clone --depth 1 --branch $(MRUBY_TAG) https://github.com/mruby/mruby $@

# 2) Build mruby itself (host mrbc + wasm32-wasi libmruby.a).
mruby: $(MRUBY_SRC)
	cd $(MRUBY_SRC) && MRUBY_CONFIG=$(CONFIG) rake

# 3) Precompile bench.rb → bench.c (C array `bench_irep[]`).
$(BUILD_DIR)/bench.c: bench.rb mruby
	@mkdir -p $(BUILD_DIR)
	$(MRUBY_SRC)/build/host/bin/mrbc -B bench_irep -o $@ bench.rb

# 4) Compile main.c.
$(BUILD_DIR)/main.o: main.c
	@mkdir -p $(BUILD_DIR)
	$(CLANG) $(CFLAGS) -c -o $@ $<

# 5) Compile bench.c.
$(BUILD_DIR)/bench.o: $(BUILD_DIR)/bench.c
	$(CLANG) $(CFLAGS) -c -o $@ $<

# 6) Link the final wasm.
$(WASM_OUT): $(BUILD_DIR)/main.o $(BUILD_DIR)/bench.o mruby
	$(CLANG) $(LDFLAGS) -o $@ $(BUILD_DIR)/main.o $(BUILD_DIR)/bench.o $(LIBS)

clean:
	rm -rf $(BUILD_DIR)

distclean: clean
	rm -rf vendor

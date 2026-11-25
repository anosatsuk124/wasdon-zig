# mruby + bench.rb -> build/mruby_bench.wasm (wasm32-wasi).
#
# Needs zig (the C compiler and wasi-libc), Ruby with rake (mruby's own
# build system), a host C compiler (for mrbc) and git.

MRUBY_TAG := 3.3.0
MRUBY     := vendor/mruby
BUILD     := build
OUT       := $(BUILD)/mruby_bench.wasm
LIB       := $(MRUBY)/build/wasm32-wasi/lib/libmruby.a
CC        := zig cc -target wasm32-wasi -Os -DMRB_NO_BOXING -DMRB_NO_PRESYM -I. -I$(MRUBY)/include

all: $(OUT)

$(MRUBY):
	git clone --depth 1 --branch $(MRUBY_TAG) https://github.com/mruby/mruby $@

$(LIB): $(MRUBY) build_config.rb shim/setjmp.h
	cd $(MRUBY) && MRUBY_CONFIG=$(abspath build_config.rb) rake

$(BUILD)/bench.c: bench.rb $(LIB)
	@mkdir -p $(BUILD)
	$(MRUBY)/build/host/bin/mrbc -B bench_irep -o $@ bench.rb

$(OUT): main.c $(BUILD)/bench.c $(LIB)
	$(CC) -o $@ main.c $(BUILD)/bench.c $(LIB)

clean:
	rm -rf $(BUILD)

distclean: clean
	rm -rf vendor

.PHONY: all clean distclean

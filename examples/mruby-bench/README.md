# mruby-bench

WASI benchmark fixture for `wasdon-zig` that statically links mruby
3.3.0 cross-compiled to `wasm32-wasi`, embeds a Ruby script as IREP
bytecode, and runs the same four workloads as
[`examples/rhai-bench/`](../rhai-bench/) (recursion, integer-loop
"mandelbrot", string concat, wall-time measurement).

The point of this example is **not** to measure mruby itself — it is to
exercise the translator's WASI Preview 1 lowering on a non-trivial C
program that drags in `wasi-libc` and a real interpreter VM.

## Producer choice: C + wasi-sdk + vendored mruby

ruby.wasm (upstream CRuby compiled to WASI) cannot run under wadson-zig
today because its libc startup mandatorily calls `fd_prestat_get` /
`path_open` / `fd_filestat_get`, all of which are deliberately
unsupported per [`docs/spec_wasi_preview_1.md`](../../docs/spec_wasi_preview_1.md)
§2.3. mruby has no such requirement: with `mruby-io` excluded from the
gembox and the Ruby script embedded as bytecode (`mrbc -B`), the
runtime touches only `fd_write`, `proc_exit`, the environ stubs, and
`clock_gettime`.

## Files

| File | Purpose |
|---|---|
| `Makefile` | Drives the wasi-sdk + mruby build. |
| `build_config.rb` | mruby cross-build config (gembox selection, toolchain). |
| `main.c` | Driver. Opens an mrb_state, times `mrb_load_irep(bench_irep)`. |
| `bench.rb` | Ruby workloads. Compiled to `build/bench.c` by `mrbc -B`. |
| `mruby_bench.udon_meta.json` | `__udon_meta` sidecar — committed. |
| `.gitignore` | Excludes `build/` and `vendor/mruby/`. |
| `README.md` | This file. |

## Prerequisites

| Tool | Why |
|---|---|
| [wasi-sdk](https://github.com/WebAssembly/wasi-sdk) | C → wasm32-wasi. Tested with wasi-sdk-22.0. Set `WASI_SDK_PATH` to its install root. |
| Ruby + `rake` | mruby's own build system shells out to Rake. Any system Ruby ≥ 3.0 works. |
| `git` | The Makefile clones mruby on first build. |

```sh
# Linux example
curl -L https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-22/wasi-sdk-22.0-linux.tar.gz | tar -xz -C /opt
export WASI_SDK_PATH=/opt/wasi-sdk-22.0

# macOS:
brew install wasi-sdk        # if available; otherwise grab the prebuilt tarball
export WASI_SDK_PATH=/usr/local/Cellar/wasi-sdk/...

# Windows: grab the .zip release; export WASI_SDK_PATH from the install dir.
```

## Build

```sh
cd examples/mruby-bench
export WASI_SDK_PATH=/opt/wasi-sdk-22.0
make
# Output: build/mruby_bench.wasm
```

The first `make` clones `mruby/mruby` at tag `3.3.0` into `vendor/mruby/`,
then cross-builds `libmruby.a` for `wasm32-wasi` and a host `mrbc`.
Subsequent builds reuse the vendored tree. Bump `MRUBY_TAG` in the
Makefile to upgrade.

## Translate

```sh
# From the workspace root.
cd ../..
zig build run -- translate \
    examples/mruby-bench/build/mruby_bench.wasm \
    --meta examples/mruby-bench/mruby_bench.udon_meta.json \
    -o /tmp/mruby_bench.uasm
```

## Expected WASI imports

A correctly-built artifact should only show entries from
`wasi_snapshot_preview1` that are in (or stubbed by) the supported set
per [`docs/spec_wasi_preview_1.md`](../../docs/spec_wasi_preview_1.md):

- `fd_write` — `printf`, `puts`
- `proc_exit` — exit at end of `_start`
- `clock_time_get` — `clock_gettime(CLOCK_MONOTONIC)`
- `environ_get` / `environ_sizes_get`, `args_get` / `args_sizes_get`,
  `fd_close`, `fd_seek`, `fd_fdstat_get` — wasi-libc `_start` glue

If any of `path_open`, `fd_prestat_get`, `fd_filestat_get`, `fd_readdir`
appear, an unwanted gem snuck into the gembox. Re-check
`build_config.rb` and rebuild from clean (`make distclean && make`).

The simplest way to inspect after translating:

```sh
grep '# wasi:' /tmp/mruby_bench.uasm | sort -u
```

## Memory sizing

`__udon_meta.options.memory` is set to `initialPages: 16, maxPages: 128`
(1 MiB initial, 8 MiB max). mruby's `mrb_state`, GC arena, and the
parsed AST eat more memory than Rhai. Bump `maxPages` if `bench.rb`
grows.

## Recursion

`__udon_meta.options.recursion = "stack"` is required because mruby's
VM dispatcher (`mrb_vm_exec`) is heavily recursive and the embedded
`fib` recurses on its own.

## Verification status

**Verified by inspection / static analysis only.** The author of this
example did not have wasi-sdk + Ruby installed on the build machine,
so the `make` pipeline below has not been executed end-to-end. The
gem selection in `build_config.rb` is the well-known
"non-IO-touching" mruby subset (compare e.g.
[mruby-wasi-build](https://github.com/kateinoigakukun/mruby-wasi-build)),
and the Makefile mirrors the standard mruby + wasi-sdk recipe. If you
hit a build error please file an issue with the failing step — it is
likely a tool-version skew rather than a structural problem.

The translator path is the same one already verified on
`examples/rhai-bench/` (also a `wasm32-wasi*` Rust binary linking
wasi-libc), so the second half of the pipeline (translate the produced
.wasm → .uasm) is not in doubt.

## Known WASI gaps surfaced by this example

None at the time of writing. `clock_time_get` and `random_get` are
fully implemented per `docs/spec_wasi_preview_1.md` §4.7 / §4.8, so
the `printf("elapsed = %.2f ms")` line should report a real wall-clock
duration. If a future mruby gembox change pulls in `mruby-io` or
similar, expect `path_open` / `fd_filestat_get` to appear and surface
as `nosys` stubs that may break startup.

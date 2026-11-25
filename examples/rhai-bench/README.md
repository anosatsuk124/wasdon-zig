# rhai-bench: a scripting engine on the Udon VM

The [Rhai](https://rhai.rs/) scripting engine — an ordinary Rust crate that
needs `std` — built for `wasm32-wasip1` and translated to Udon Assembly. It
parses and interprets a script holding the three workloads of
[`examples/bench`](../bench/): `fib(20)`, an integer Mandelbrot grid, and
64 string appends, and prints the results through `print` → `fd_write` →
`Debug.Log`.

Nothing in `src/main.rs` knows about Udon. The module imports only WASI
preview 1 (`docs/spec_wasi_preview_1.md`).

## Why it is here

It is the largest program the translator is tested on, by two orders of
magnitude, and the kind of code that finds translator bugs: 3 360
functions, a megabyte of WebAssembly, an allocator, hashing, trait objects
called through the function table, deep mutual recursion.

| | |
|---|---:|
| WebAssembly | 1 105 170 bytes, 3 360 functions |
| Udon Assembly | 1 180 797 instructions, 211 912 `EXTERN`s, heap 56 412 slots |
| executed | 624 933 773 instructions, 109 765 017 `EXTERN`s |

The same three workloads compiled ahead of time
([`examples/bench/wasi-rs`](../bench/wasi-rs/)) execute 185 936 externs, so
interpreting them costs about 590 times as much. This example is a test of
the translator, not a recommendation: one Udon event has ten seconds, and
this run does not fit in them. A script interpreter in a world has to be
stepped over many frames, the way [`examples/pi`](../pi/) steps its
computation.

Bringing it up found three bugs in the translator that no smaller program
had reached; each now has a small executed test
(`src/translator/tests.zig`: a local read before a re-entrant call and used
after it, a value carried by `br_if`, `p = p.next` followed by a read
through `p`). `docs/udon_vm.md` §5 describes the tools that located them.

## Build and run

It is not part of `-Drust`: it downloads the `rhai` crate and takes most of
a minute to translate, check and run in a debug build.

```sh
rustup target add wasm32-wasip1
zig build test -Drhai          # translate, check, execute, compare the output
zig build stats -Drhai         # its row in the statistics table
```

By hand:

```sh
cargo build --release --target wasm32-wasip1 -p rhai-bench
zig build -Doptimize=ReleaseFast
zig-out/bin/wasdon_zig translate target/wasm32-wasip1/release/rhai_bench.wasm -o rhai.uasm
zig-out/bin/wasdon_zig run rhai.uasm --events _start
```

```
[info] fib(20) = 6765        (0 ns)
[info] mandel  = 1345        (0 ns)
[info] str.len = 192        (0 ns)
[info] total   = 0 ns
```

The emulator's clock only advances between frames, so the timings the
script measures are zero there.

The crate is built with `only_i32`, `f32_float` and `unchecked`
(`Cargo.toml`): 32-bit integers are the cheap ones on the Udon VM
(`docs/producer_guide.md`).

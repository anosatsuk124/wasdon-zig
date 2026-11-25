# Examples

Programs written for the Udon VM in Zig and Rust, translated by
wasdon-zig. Every one is translated, checked and executed by `zig build
test`; `zig build stats` prints what each costs (`docs/benchmarks.md`).

| Example | What it shows |
|---|---|
| [`pi`](pi/) | A long computation cut into per-frame steps: digits of π by an integer spigot. |
| [`mandelbrot`](mandelbrot/) | Floating point, and pixels computed in linear memory and uploaded to a texture with three externs per frame. |
| [`image-codec`](image-codec/) | Byte-level parsing: a complete, incremental QOI decoder and encoder, with pictures shipped in the program's data. |
| [`ragdoll`](ragdoll/) | A humanoid of sixteen point masses: Verlet physics, an animated pose, and a wander / knocked-down / get-up state machine. |
| [`blockfall`](blockfall/) | World logic: a falling-block puzzle shared by everyone in the instance — custom events, ownership, manual sync of the whole state as one `byte[]`. |
| [`bench`](bench/) | The same three workloads in UdonSharp, Zig and Rust, measured against each other. |
| [`wasi-hello`](wasi-hello/), [`bench/wasi-rs`](bench/wasi-rs/) | Ordinary programs with a `main`, built for WASI: Zig's and Rust's `std`, nothing Udon-specific in the source. |
| [`rhai-bench`](rhai-bench/) | A whole scripting engine (Rhai, Rust `std`) interpreting the benchmark's workloads: the translator's largest test, built with `-Drhai`. |
| [`udon-orbit`](udon-orbit/), [`udon-orbit-rs`](udon-orbit-rs/) | The basics, in Zig and Rust: Inspector fields, object handles, instantiating a prefab. |
| [`wasm-bench`](wasm-bench/), [`wasm-bench-rs`](wasm-bench-rs/), [`wasm-bench-alloc-rs`](wasm-bench-alloc-rs/) | A self-checking tour of the WebAssembly instruction set; the last one with a heap allocator. |
| [`linux`](linux/) | What happens when the input is the Linux kernel built for WebAssembly. |

Layout of the Zig examples:

- `core.zig` — the logic, with no Udon in it. The tests also compile it
  natively and compare the Udon run with it, bit for bit.
- `main.zig` — the events, the Udon variables (`__udon_meta`) and the
  externs that show the result.
- [`udon/udon.zig`](udon/udon.zig) — the Udon bindings they share.

In Unity: `unity/Wasdon/Examples/` has each example as an asset, and
`Tools > Wasdon > Create Example Objects` builds a scene object for each
(`unity/Wasdon/README.md`).

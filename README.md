# wasdon-zig

A translator from **WebAssembly** to **Udon Assembly** — the textual form of
the bytecode VRChat's Udon VM executes. Written in Zig.

`wasdon` = **Wa**SM → U**don**.

Udon programs are normally written in Udon Graph or UdonSharp. `wasdon-zig`
opens a third path: compile Zig, Rust, C — anything that targets
WebAssembly — and translate the result. The repository also contains an
Udon VM emulator and an Udon Assembly checker, so translated programs can be
verified and measured without Unity.

## What makes this hard

- **No local variables, no value stack.** Every value is a field of the
  UdonBehaviour. WASM locals and the operand stack become heap slots.
- **No call or return.** Only `JUMP`, `JUMP_IF_FALSE`, `JUMP_INDIRECT`; the
  translator synthesizes a calling convention.
- **No arithmetic.** Every operation is an `EXTERN` on a .NET method, and
  slots are strictly typed.
- **No raw memory.** Linear memory is a .NET `byte[]`.

Because `EXTERN` dominates run time on the Udon VM, the translator is built
around emitting as few of them as possible. On the same workloads, Zig and
Rust translated this way execute 1.5–1.7× fewer externs than UdonSharp
(`examples/bench`); `docs/benchmarks.md` has every measurement.

## Status

- [x] WASM Core 1 parser, plus sign-extension, non-trapping float-to-int and
      bulk-memory instructions
- [x] Every Core 1 numeric instruction (`i32` / `i64` / `f32` / `f64`,
      including unsigned operations, rotations, `clz`/`ctz`/`popcnt`,
      conversions) — `docs/spec_numeric_conversion.md`
- [x] Structured control flow, direct and indirect calls, recursion, the
      start function — `docs/spec_call_return_conversion.md`
- [x] Linear memory: all load/store widths at any alignment, `memory.grow`,
      `memory.copy`, `memory.fill`, passive data segments
      (`memory.init`, `data.drop`) — `docs/spec_linear_memory.md`
- [x] Udon externs as imports, with string marshalling, `ref`/`out`
      arguments and opaque object handles —
      `docs/spec_host_import_conversion.md`
- [x] `__udon_meta`: events, Inspector/synced fields, options —
      `docs/spec_udonmeta_conversion.md`
- [x] WASI preview 1: programs built for `wasm32-wasi` / `wasm32-wasip1`
      (Rust and Zig `std`, wasi-libc) run as they are, stdout to the Unity
      console — `docs/spec_wasi_preview_1.md`
- [x] Udon Assembly conformance checker and Udon VM emulator —
      `docs/udon_vm.md`
- [x] Unity editor support and the examples as ready-made assets —
      `unity/Wasdon/`
- [ ] Not supported: multi-value block parameters, reference types
      beyond the `call_indirect` encoding, SIMD, threads,
      tail calls, exceptions (`wasdon_zig inspect` lists what a module
      needs)

## Getting started

Zig 0.16 is required (pinned in `mise.toml`).

```sh
zig build                      # the CLI: zig-out/bin/wasdon_zig
zig build test                 # unit + integration tests
zig build examples             # example modules: zig-out/wasm/*.wasm
zig build stats                # size and executed-instruction table for every example
zig build unity                # regenerate unity/Wasdon/Examples from the examples
```

Add `-Drust` to include the Rust examples (needs `cargo` and the
`wasm32v1-none` and `wasm32-wasip1` targets).

```sh
wasdon_zig inspect app.wasm
wasdon_zig translate app.wasm -o app.uasm --stats
wasdon_zig check app.uasm
wasdon_zig run app.uasm --events "_start,_update*60,_interact" --profile
```

- `inspect` reports a module's size, its imports, and everything in it the
  translator does not support.
- `translate` writes Udon Assembly and, with `--stats`, the heap size and
  instruction counts of the result. `--meta file.json` supplies
  `__udon_meta` from a file.
- `check` validates Udon Assembly against the language rules and the Udon
  node list.
- `run` executes it in the emulator and reports the instructions and
  externs each event executed.

### A minimal program

```zig
extern "env" fn @"UnityEngineDebug.__Log__SystemString__SystemVoid"(ptr: [*]const u8, len: usize) void;

export fn _start() void {
    const msg = "hello from WebAssembly";
    @"UnityEngineDebug.__Log__SystemString__SystemVoid"(msg.ptr, msg.len);
}
```

An import named after an Udon extern signature is called as that extern; an
exported function named after an Udon event becomes that event. Metadata is
only needed for Inspector fields, synced variables and options
(`docs/producer_guide.md`).

Or, with no Udon in the source at all:

```rust
fn main() {
    println!("hello from Rust's std");
}
```

```sh
cargo build --release --target wasm32-wasip1
wasdon_zig translate target/wasm32-wasip1/release/app.wasm -o app.uasm
```

### Examples

`examples/` has the programs the tests run and measure: digits of π, a
Mandelbrot renderer, a QOI image codec, a physically simulated humanoid, a
networked falling-block puzzle, WASI programs, and a benchmark against
UdonSharp. See `examples/README.md`.

### In Unity

Copy `unity/Wasdon/` into your project's `Assets/` folder and create a
**Wasdon Assembly Program Asset**
(`Create > VRChat > Udon > Wasdon Assembly Program Asset`). It sizes the
Udon heap from the program; the stock Udon Assembly Program Asset only fits
programs of up to 512 heap slots (`docs/spec_heap_size.md`).

## Layout

```
docs/                        Specifications — read before changing the translator
src/
├─ wasm/                     WASM binary parser, __udon_meta decoding
├─ udon/                     Udon Assembly: writer, reader, checker, VM emulator, node list
├─ translator/               WASM → Udon lowering
│  ├─ translate.zig              module level: reachability, memory, globals, events, init
│  ├─ lower.zig                  function bodies: operand stack, control flow, calls, memory
│  ├─ callgraph.zig              call graph and recursion detection
│  ├─ liveness.zig               live locals at calls; locals that are only conditions
│  ├─ wasi.zig                   WASI preview 1, linked in as WebAssembly
│  └─ inspect.zig                what a module needs (`wasdon_zig inspect`)
├─ root.zig                  library surface (`@import("wasdon_zig")`)
└─ main.zig                  CLI
test/                        integration tests and the statistics tool over examples/
tools/                       generator for the examples' Unity assets
examples/                    producer-side examples (Zig, Rust, UdonSharp for comparison)
unity/Wasdon/                Unity editor support and the examples as assets
```

## Using it as a library

```zig
const wasdon_zig = @import("wasdon_zig");

pub fn translate(gpa: std.mem.Allocator, wasm_bytes: []const u8, out: *std.Io.Writer) !void {
    const stats = try wasdon_zig.translateBytes(gpa, wasm_bytes, out, .{});
    std.log.info("heap size {d}", .{stats.heapSize()});
}
```

`wasdon_zig.wasm`, `.udon` and `.translator` are importable on their own.

## Testing

Tests do not stop at "the output looks right". Every example and every
synthesized module is translated, **checked** against the Udon Assembly
rules and the node list, **executed** in the emulator, and compared with its
expected behaviour. Execution on the real Udon VM still needs Unity; the
emulator follows the behaviour documented in `docs/udon_vm.md`.

## License

[Apache License 2.0](LICENSE).

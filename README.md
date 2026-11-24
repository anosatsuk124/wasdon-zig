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
around emitting as few of them as possible. See `docs/benchmarks.md` for
measurements.

## Status

- [x] WASM Core 1 parser, plus sign-extension, non-trapping float-to-int and
      bulk-memory instructions
- [x] Every Core 1 numeric instruction (`i32` / `i64` / `f32` / `f64`,
      including unsigned operations, rotations, `clz`/`ctz`/`popcnt`,
      conversions) — `docs/spec_numeric_conversion.md`
- [x] Structured control flow, direct and indirect calls, recursion, the
      start function — `docs/spec_call_return_conversion.md`
- [x] Linear memory: all load/store widths at any alignment, `memory.grow`,
      `memory.copy`, `memory.fill` — `docs/spec_linear_memory.md`
- [x] Udon externs as imports, with string marshalling, `ref`/`out`
      arguments and opaque object handles —
      `docs/spec_host_import_conversion.md`
- [x] `__udon_meta`: events, Inspector/synced fields, options —
      `docs/spec_udonmeta_conversion.md`
- [x] Udon Assembly conformance checker and Udon VM emulator —
      `docs/udon_vm.md`
- [ ] Not supported: passive data segments, multi-value block parameters,
      reference types, SIMD, threads, tail calls, exceptions

## Getting started

Zig 0.16 is required (pinned in `mise.toml`).

```sh
zig build                      # the CLI: zig-out/bin/wasdon_zig
zig build test                 # unit + integration tests
zig build examples             # example modules: zig-out/wasm/*.wasm
zig build stats                # size and executed-instruction table for every example
```

Add `-Drust` to include the Rust examples (needs `cargo` and the
`wasm32v1-none` target).

```sh
wasdon_zig translate app.wasm -o app.uasm --stats
wasdon_zig check app.uasm
wasdon_zig run app.uasm --events "_start,_update*60,_interact" --profile
```

- `translate` writes Udon Assembly and, with `--stats`, the heap size and
  instruction counts of the result.
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
│  └─ callgraph.zig              call graph and recursion detection
├─ root.zig                  library surface (`@import("wasdon_zig")`)
└─ main.zig                  CLI
test/                        integration tests and the statistics tool over examples/
examples/                    producer-side examples (Zig and Rust)
unity/Wasdon/                Unity editor support
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

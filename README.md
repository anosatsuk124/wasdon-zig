# wasdon-zig

A binary translator from **WebAssembly (Core 1 / MVP)** to **Udon Assembly** — the textual form executed by VRChat's Udon VM. Written in Zig.

The name `wasdon` = **Wa**SM → U**don**.

## Overview

VRChat's Udon VM is a custom bytecode interpreter that runs inside a .NET sandbox. Assembly is usually produced by Udon Graph or UdonSharp; `wasdon-zig` opens a second path by taking arbitrary WASM as input and emitting equivalent assembly, so you can author Udon-world behaviour in C, Rust, Zig, AssemblyScript, or any language that targets WebAssembly.

The translator's main design challenges come from Udon's unusual constraints:

- **No local variables.** Everything is a field on the UdonBehaviour (on the heap). WASM locals and the WASM value stack are all flattened into per-function heap slots.
- **No call / return instructions.** Only `JUMP`, `JUMP_INDIRECT`, and `JUMP_IF_FALSE` exist. The translator synthesises a return-address-constant (RAC) based ABI.
- **No raw byte memory.** WASM linear memory is lowered to a two-level chunked array (`SystemObjectArray` × `SystemUInt32Array`); byte-level access expands to shift/mask sequences.
- **Host calls are `EXTERN` with .NET signature strings.** Import names themselves are parsed as Udon extern signatures and dispatched generically — no per-import tables, no translator edits for new externs.

The authoritative design is in `docs/`; each `spec_*.md` covers one translation concern.

## Status

Covers enough of the surface to translate `examples/wasm-bench` structurally end to end:

- [x] WASM Core 1 / MVP binary parser (types, imports/exports, code, data, element, custom/name)
- [x] `__udon_meta` JSON metadata extraction from data segments
- [x] Arithmetic (full i32 / i64 / f64 via EXTERN signatures)
- [x] Structured control flow (block / loop / if-else / br / br_if / br_table / return)
- [x] Locals and globals (`__{fn}_P{i}__` / `__{fn}_L{i}__` / `__G__{name}` naming)
- [x] Direct calls with the RAC-based ABI
- [x] Full `call_indirect` (shared `__ind_P*` / `__ind_R*` + per-function indirect entry + trampoline)
- [x] Linear memory `i32.load` / `i32.store` with compile-time aligned fast path and 3-branch (unaligned within-chunk / page-straddling) fallback, plus `i64.load` / `i64.store` word-pair combine, `memory.size`
- [x] Full `i32.load8_*` / `i32.store8` and `i32.store16` shift/mask RMW expansion
- [x] `memory.grow` real allocation (per-page `SystemUInt32Array` ctor + outer `SetValue`, bounds-checked against `maxPages`)
- [x] Conversion opcodes (`i32.wrap_i64`, `i64.extend_i32_*`, `i{32,64}.trunc_f{32,64}_{s,u}`, `f{32,64}.convert_i{32,64}_{s,u}`, `f32.demote_f64`, `f64.promote_f32`, `{i,f}{32,64}.reinterpret_{f,i}{32,64}`)
- [x] Host import dispatch via signature grammar, with `SystemString` marshalling from `(ptr, len)`
- [x] `__udon_meta.functions` → Udon event-label mapping (`_start` / `_update` / `_interact` / …)
- [x] Recursive-function call-stack spill (opt-in via `__udon_meta.options.recursion = "stack"`, Tarjan-SCC based detection, prologue/epilogue spill of P / L / R / RA onto `__call_stack__`)
- [x] CLI (`translate <in.wasm> [-o <out.uasm>]`)
- [ ] `i32.trunc_sat_*` (0xFC prefix, post-MVP) and other non-MVP extensions

## Getting started

### Build

Zig 0.16+ is required (pinned via `mise.toml`).

```sh
zig build                 # builds the CLI into zig-out/bin/wasdon_zig
zig build test            # runs the full test suite (162 tests)
zig build wasm-example    # compiles examples/wasm-bench/main.zig to MVP WASM and copies it into the testdata dirs
```

### Translate

```sh
# build the bench fixture, then translate it (sidecar bench.udon_meta.json
# is auto-discovered next to bench.wasm)
zig build wasm-example
zig build run -- translate src/translator/testdata/bench.wasm -o /tmp/bench.uasm

# or use the installed binary directly
./zig-out/bin/wasdon_zig translate path/to/input.wasm -o output.uasm

# pass an explicit __udon_meta sidecar
./zig-out/bin/wasdon_zig translate path/to/input.wasm \
    --meta path/to/input.udon_meta.json -o output.uasm
```

Omit `-o` to write to stdout. Omit `--meta` and the CLI looks for
`<wasm-stem>.udon_meta.json` next to the `.wasm` input; if no sidecar
is found, translation proceeds with translator defaults.

### Writing your own WASM

Host functions are declared with Zig's raw-identifier syntax using the Udon extern signature as the import name:

```zig
extern "env" fn @"SystemConsole.__WriteLine__SystemString__SystemVoid"(
    ptr: [*]const u8,
    len: usize,
) void;

export fn on_start() void {
    const msg = "hi";
    @"SystemConsole.__WriteLine__SystemString__SystemVoid"(msg.ptr, msg.len);
}
```

The translator parses the import name against the Udon extern signature grammar (`docs/udon_specs.md` §7) and dispatches it generically, so adding new externs never requires touching the translator. `SystemString` arguments are automatically UTF-8 decoded from the `(ptr, len)` pair.

For an end-to-end walkthrough — toolchain pinning (Zig + Rust `wasm32v1-none`), Cargo workspace layout, host-import declarations, mutable-state limitations, the `__udon_meta` sidecar JSON contract, recursion opt-in, and the build → translate pipeline — see [`docs/producer_guide.md`](docs/producer_guide.md). Working examples live under `examples/` (Zig: `wasm-bench`, `udon-orbit`; Rust: `wasm-bench-rs`, `udon-orbit-rs`).

Udon-side field names, events, sync modes, and memory sizing are configured via a `__udon_meta` JSON file that ships alongside the `.wasm` (see `docs/spec_udonmeta_conversion.md`). For `bench.wasm`, the translator auto-discovers `bench.udon_meta.json` in the same directory:

```json
{
  "version": 1,
  "functions": {
    "start": { "source": {"kind":"export","name":"on_start"}, "label":"_start", "export": true, "event":"Start" }
  },
  "fields": {
    "counter": { "source":{"kind":"global","name":"counter"}, "udonName":"_counter", "type":"int", "export": true }
  },
  "options": {
    "memory": { "initialPages": 1, "maxPages": 16 }
  }
}
```

The Wasm binary contains nothing related to `__udon_meta` — no exports, no data segments, no globals are reserved for it.

## Project layout

```
docs/                       # Specs — the source of truth for translation strategy
├─ udon_specs.md                   # Udon Assembly reference
├─ w3c_wasm_binary_format_note.md  # Notes on the WASM Core 1 binary format
├─ spec_variable_conversion.md     # WASM locals/globals → Udon field naming
├─ spec_linear_memory.md           # Linear memory → two-level chunked array
├─ spec_call_return_conversion.md  # Synthesising call/return from RAC + JUMP_INDIRECT
├─ spec_udonmeta_conversion.md     # __udon_meta JSON schema and resolution rules
├─ spec_host_import_conversion.md  # Generic host-import dispatch via signature grammar
└─ producer_guide.md               # Producer-side guide: writing WASM that the translator accepts (Zig, Rust on wasm32v1-none, raw WAT)

src/
├─ wasm/                   # WASM Core 1 / MVP binary parser (translator-agnostic)
├─ udon/                   # Udon Assembly construction primitives (type-name encoder + asm writer + 2-pass layout)
├─ translator/             # WASM → Udon lowering core
│  ├─ names.zig                 # Naming-convention helpers
│  ├─ lower_numeric.zig         # opcode → EXTERN signature dispatch table
│  ├─ extern_sig.zig            # Udon extern signature parser
│  ├─ lower_import.zig          # Generic host-import dispatcher + type-erased Host interface
│  └─ translate.zig             # Per-instruction lowering, call ABI, call_indirect, memory init, event entries
├─ root.zig                # Library surface
└─ main.zig                # CLI

examples/                   # Producer-side fixtures (also serve as worked examples for docs/producer_guide.md)
├─ wasm-bench/             # Zig → MVP WASM bench fixture
├─ wasm-bench-rs/          # Rust port of wasm-bench (wasm32v1-none, no_std)
├─ udon-orbit/             # Zig VRChat orbit-and-clone showcase
└─ udon-orbit-rs/          # Rust port of udon-orbit
```

## Testing

`zig build test` runs 185 unit and integration tests:

- Parser tests in `src/wasm/*.zig` (including `__udon_meta` parse coverage for `options.recursion`)
- Assembly writer tests in `src/udon/*.zig`
- Signature-parser tests in `src/translator/extern_sig.zig`, including a regression round-trip over the entire numeric EXTERN table
- Call-graph / Tarjan SCC tests in `src/translator/recursion.zig` (self-recursion, mutual recursion, linear chains)
- Mock-`Host`-based tests for the generic import dispatcher in `src/translator/lower_import.zig`
- End-to-end structural assertions in `src/translator/translate.zig` that `@embedFile` the compiled `bench.wasm` and check the emitted assembly, plus synthesized-module tests for unaligned memory access and recursion spill

Execution on the real Udon VM depends on the VRChat runtime and cannot be validated from CI, so the translator's responsibility stops at "emit a structurally spec-conformant Udon Assembly program."

## Using it as a library

Add `wasdon-zig` as a dependency in `build.zig.zon` and `@import("wasdon_zig")`:

```zig
const wasdon_zig = @import("wasdon_zig");

pub fn translate_wasm(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    udon_meta_json: ?[]const u8, // pass `null` for "no meta"
    writer: *std.Io.Writer,
) !void {
    try wasdon_zig.translateBytes(gpa, wasm_bytes, udon_meta_json, writer, .{});
}
```

The sub-modules (`wasdon_zig.wasm` / `.udon` / `.translator`) are independently importable — if you only need the WASM parser, pull the `wasm` module alone.

## License

[Apache License 2.0](LICENSE).

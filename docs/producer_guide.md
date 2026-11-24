# Producer guide: writing WASM that wasdon-zig can translate

Audience: anyone writing the WASM module the translator consumes. The
`spec_*.md` files describe what the translator does; this guide describes
what your program must look like, and what makes it fast on the Udon VM.

Working examples that follow every rule below live under `examples/`.

---

## 1. Target features

The translator accepts WebAssembly Core 1 (MVP) plus:

| Proposal | Why you want it |
|---|---|
| **bulk memory** (`memory.copy`, `memory.fill`) | `memcpy`/`memset` become **one extern** instead of a byte loop costing several externs per byte. The single biggest producer-side win. |
| sign-extension operators | two instructions each |
| non-trapping float-to-int | supported |
| mutable-global import/export | supported |

Not supported: multi-value block parameters, reference types, passive data
segments (`memory.init` / `data.drop`), SIMD, threads/atomics, tail calls,
exception handling, memory64.

| Toolchain | Setup |
|---|---|
| Zig | `wasm32-freestanding`, CPU model `mvp` plus features `bulk_memory_opt`, `sign_ext`, `nontrapping_fptoint`, `mutable_globals` — see `build.zig`. `bulk_memory_opt` gives `memory.copy`/`memory.fill` without passive segments; the default `generic` model also enables multi-value and reference types, which are rejected. |
| Rust | `wasm32v1-none` (MVP only) works as is; the examples in this repository use it. Add `-C target-feature=+bulk-memory` to get `memory.copy` / `memory.fill` in your own code (the precompiled standard library keeps its software `memcpy` unless rebuilt with `-Zbuild-std`). |
| C / other | Equivalent `-m` flags; check the output with the translator, which names the first unsupported construct. |

---

## 2. Project layout (Rust)

```toml
# Cargo.toml (workspace root)
[profile.release]
opt-level = "z"
lto = true
codegen-units = 1
panic = "abort"
strip = "symbols"
```

```toml
# .cargo/config.toml
[build]
target = "wasm32v1-none"
```

```toml
# examples/<name>-rs/Cargo.toml
[lib]
crate-type = ["cdylib"]
```

- `opt-level = "z"` + `lto` + `codegen-units = 1` make the
  `__udon_meta_ptr` / `_len` functions fold to constants (§6).
- `panic = "abort"`: there is no unwinder.
- Cargo turns hyphens into underscores: `udon-orbit-rs` builds
  `target/wasm32v1-none/release/udon_orbit_rs.wasm`.

---

## 3. `no_std` skeleton (Rust)

```rust
#![no_std]

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    core::arch::wasm32::unreachable()
}
```

Prefer `unreachable()` to `loop {}`: `unreachable` becomes a logged trap
that ends the event, while an infinite loop runs until Udon's 10-second
watchdog halts the behaviour.

`alloc` works with any `#[global_allocator]`; see
`examples/wasm-bench-alloc-rs` for a bump allocator over a static arena.

---

## 4. Calling Udon (host imports)

An import whose **name** is an Udon extern signature from
`docs/udon_nodes.txt` is called as that extern. Full rules:
`docs/spec_host_import_conversion.md`.

```zig
extern "env" fn @"UnityEngineDebug.__Log__SystemString__SystemVoid"(ptr: [*]const u8, len: usize) void;
extern "env" fn @"UnityEngineTransform.__set_position__UnityEngineVector3__SystemVoid"(self: i32, pos: i32) void;
```

```rust
#[link(wasm_import_module = "env")]
unsafe extern "C" {
    #[link_name = "UnityEngineDebug.__Log__SystemString__SystemVoid"]
    fn debug_log(ptr: *const u8, len: usize);
}
```

- Instance methods take the receiver as an extra first parameter.
- `SystemString` parameters are a `(pointer, length)` pair of UTF-8 bytes.
- `SystemBoolean` is an `i32` 0/1; `SystemSingle` an `f32`; and so on.
- Every other Udon type is an **opaque `i32` handle**.

### Handles

A handle is not a number. **Never compute with it, compare it, or store it
in memory** (a struct field, an array, a `static`). Keep it in a local, pass
it on, or put it in an Udon variable (§5). Rust and Zig keep such values in
WASM locals as long as their address is not taken.

### Cost

Each extern call costs the same on the Udon VM regardless of what it does,
so prefer coarse calls:

- one `Buffer.BlockCopy` + `Texture2D.LoadRawTextureData` instead of
  per-pixel `SetPixel`;
- `Transform.SetPositionAndRotation` instead of two property sets;
- computing in WASM and handing over the result once.

---

## 5. Sharing state with Udon (`__udon_meta.fields`)

Three kinds of field, by where the value lives
(`docs/spec_udonmeta_conversion.md`):

| `source.kind` | Value lives in | Use it for |
|---|---|---|
| `import` | the Udon heap; WASM reads/writes through a getter/setter import pair | anything Udon-typed: object references, synced values, values other behaviours read, event parameters |
| `symbol` | linear memory, at an exported address | Inspector-tunable inputs for ordinary `static`/`var` variables (copied in once at startup) |
| `global` | a WASM global | hand-written WAT |

```zig
export var radius: f32 = 1.5;                       // kind: symbol
extern "env" fn @"udon.self"() i32;                  // kind: import, type transform, default "this"
extern "env" fn @"udon.score"() i32;                 // kind: import, getter
extern "env" fn @"udon.set_score"(v: i32) void;      //               setter
```

`examples/udon-orbit` uses all of them.

---

## 6. `__udon_meta` discovery

The translator finds the JSON through two exports: `__udon_meta_ptr`
(address) and `__udon_meta_len` (byte length). Each must be an exported
constant global, or an exported nullary function whose body is exactly one
`i32.const` or one `global.get` of such a global. The translator never
executes WASM.

```zig
const udon_meta_json = \\{ "version": 1, ... };
export fn __udon_meta_ptr() [*]const u8 { return udon_meta_json.ptr; }
export fn __udon_meta_len() u32 { return @intCast(udon_meta_json.len); }
```

```rust
const UDON_META_JSON: &[u8] = br#"{ "version": 1, ... }"#;
#[unsafe(no_mangle)] pub extern "C" fn __udon_meta_ptr() -> *const u8 { UDON_META_JSON.as_ptr() }
#[unsafe(no_mangle)] pub extern "C" fn __udon_meta_len() -> u32 { UDON_META_JSON.len() as u32 }
```

| Error | Cause |
|---|---|
| `NonConstMetaLocator` | The locator function did not fold to a constant. Build optimized (§2). |
| `MetaSpansMultipleSegments` | The JSON crosses a data-segment boundary. Keep it one literal. |
| `MetaRangeOutOfData` | The address is covered by no data segment. |
| Defaults used silently | One of the two exports is missing. |

Metadata is optional. Without it, every exported function with no
parameters and no results becomes an event named after its export
(`export fn _start()`, `export fn _update()`).

---

## 7. Events and time

- Udon gives each event **10 seconds**; exceeding it halts the behaviour
  permanently. Split long work across `_update` calls and keep the state in
  ordinary variables (`examples/pi`, `examples/mandelbrot`).
- Initialization (memory, data segments, the WASM start function) runs
  before the first event delivered, whichever that is, and only once.
- An event function takes no parameters.

---

## 8. Recursion

Every function has one static frame. Functions on a call-graph cycle save
and restore their frame around the recursive call automatically
(`docs/spec_call_return_conversion.md` §6), at a cost of four externs per
saved slot per call. Deep or hot recursion is slow on Udon; prefer loops.

A program whose only "cycles" come from function pointers that never
actually recurse can set `"options": { "recursion": "disabled" }`.

---

## 9. Memory

- Linear memory is one .NET `byte[]`; loads are 1–2 externs, stores 2, at
  any alignment (`docs/spec_linear_memory.md`).
- The initial size is the module's declared minimum. Zig reserves 1 MiB of
  stack by default (17 pages); lower it if you instantiate many behaviours.
- `memory.grow` reallocates and copies; grow rarely and in large steps.
- Values that live in WASM locals cost nothing to read. Values in memory
  cost an extern per access — keep hot state in locals where the compiler
  allows it.

---

## 10. Build, translate, check, run

```sh
zig build                      # the translator: zig-out/bin/wasdon_zig
zig build examples             # example modules: zig-out/wasm/*.wasm

wasdon_zig translate app.wasm -o app.uasm --stats
wasdon_zig check app.uasm      # Udon Assembly rules + node list + heap size
wasdon_zig run app.uasm --events "_start,_update*60,_interact" --profile
```

`run` executes the program in the bundled Udon VM emulator
(`docs/udon_vm.md`) and reports instructions and externs executed per
event; `--profile` lists the externs by execution count, which is where to
look when optimizing.

In Unity, use a **Wasdon Assembly Program Asset** (`unity/Wasdon/`), which
sizes the Udon heap from the program (`docs/spec_heap_size.md`). The stock
Udon Assembly Program Asset only holds programs of up to 512 heap slots.

---

## Checklist

- [ ] Bulk memory enabled; no multi-value, reference types, or threads.
- [ ] Every extern import name appears verbatim in `docs/udon_nodes.txt`
      (`translate --strict` checks).
- [ ] Handles never stored in memory or used as numbers.
- [ ] `__udon_meta_ptr` / `_len` fold to constants (or no metadata at all).
- [ ] No event runs longer than its share of a frame, let alone 10 s.
- [ ] `wasdon_zig check` reports 0 errors; `wasdon_zig run` behaves.

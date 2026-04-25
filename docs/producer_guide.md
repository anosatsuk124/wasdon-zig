# Producer guide: writing WASM that wasdon-zig can translate

Audience: anyone writing a WASM module that the wasdon-zig translator
will consume. This document is the **producer-side** counterpart to the
`spec_*.md` files — those describe what the translator does, this one
describes what your source program must look like for that translation
to succeed.

The schemas of `__udon_meta` itself, the Udon Assembly target language,
and the WASM-side ABI conversions are covered in
[`spec_udonmeta_conversion.md`](spec_udonmeta_conversion.md),
[`udon_specs.md`](udon_specs.md), and the various
[`spec_*_conversion.md`](.) files. This guide collects the practical
constraints you have to obey to produce binaries the translator accepts.

Working examples that follow every rule below live under
`examples/` (Zig: `wasm-bench`, `udon-orbit`; Rust:
`wasm-bench-rs`, `udon-orbit-rs`).

---

## 1. Target the WebAssembly MVP, not "modern" WASM

The translator is a Core 1 / MVP parser. It rejects post-MVP opcodes
(`i32.trunc_sat_*`, anything in the `0xFC` prefix, sign-extension ops,
bulk-memory, multi-value results, reference types, mutable globals from
the `mutable-globals` proposal, etc.) with `UnknownOpcode` or related
parse errors.

You **must** pin your toolchain to MVP-only output:

| Toolchain | What to do                                                          |
|-----------|---------------------------------------------------------------------|
| Zig       | `cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp }` on a `wasm32-freestanding` target. The default `generic` model enables `sign-ext` / `bulk-memory` / `multivalue` / `mutable-globals` / `nontrapping-fptoint` / `reference-types`, all of which the parser refuses. See `build.zig` in this repo for the canonical setup. |
| Rust      | Use the `wasm32v1-none` target — it is the official "WASM 1.0 / MVP only" target and disables every post-MVP feature by default. `wasm32-unknown-unknown` will *not* work without aggressive `-C target-feature=-…` flags, and even then is a moving target. |
| WAT/wasm-tools | Hand-author or process with `wasm-tools` and avoid the proposal extensions. |

### Implication: no mutable WASM globals

The MVP only allows immutable globals. The Rust target enforces this
strictly: Rust `static mut` variables live in **linear memory**, with
their address exported as an immutable i32 global. Zig with the MVP CPU
model behaves the same way. There is no language-level workaround on
the producer side; design your `__udon_meta.fields` accordingly
(see [§5](#5-state--__udon_metafields)).

---

## 2. Project layout (Rust)

A two-crate Cargo workspace (one per example) with the wasm target as
the build default works cleanly:

```
Cargo.toml                 # workspace + release profile
.cargo/config.toml         # default --target = wasm32v1-none
examples/<name>-rs/
├─ Cargo.toml              # crate-type = ["cdylib"]
└─ src/lib.rs
```

```toml
# Cargo.toml (workspace root)
[workspace]
resolver = "2"
members = ["examples/udon-orbit-rs", "examples/wasm-bench-rs"]

[workspace.package]
edition = "2021"
publish = false

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
[package]
name = "<name>-rs"
version = "0.0.0"
edition.workspace = true
publish.workspace = true

[lib]
crate-type = ["cdylib"]
path = "src/lib.rs"
```

The release profile is **load-bearing**:

- `opt-level = "z"` + `lto = true` + `codegen-units = 1` is what makes
  `__udon_meta_ptr`/`_len` collapse to a single `i32.const` (see
  [§6](#6-__udon_meta-discovery-contract)).
- `panic = "abort"` prevents pulling in unwinding support that
  freestanding WASM cannot link.
- `strip = "symbols"` keeps the binary small and removes debug-info
  imports the translator does not understand.

Install the target once with `rustup target add wasm32v1-none`.

### File-name mapping

Cargo turns hyphens in the crate name into underscores in the output
file name. `udon-orbit-rs` produces `target/wasm32v1-none/release/udon_orbit_rs.wasm`.

---

## 3. `no_std` skeleton (Rust)

The translator's runtime environment is the Udon VM; there is no OS,
no allocator, no thread, no panic infrastructure. Every Rust crate
must:

```rust
#![no_std]

use core::panic::PanicInfo;

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    loop {}
}
```

WASM-specific intrinsics like `memory.size`/`memory.grow` are exposed
through `core::arch::wasm32`:

```rust
let pages_before = core::arch::wasm32::memory_size(0) as i32;
let prev = core::arch::wasm32::memory_grow(0, 1) as i32;
```

These are safe to call directly — they lower to the matching MVP
opcodes, no `unsafe` needed.

---

## 4. Declaring host imports (Udon externs)

Every Udon EXTERN is reached through a WASM function import whose name
is the *verbatim* Udon-extern signature string from
`docs/udon_nodes.txt`. The import module is conventionally `"env"`.
The translator parses this name against the signature grammar in
`docs/udon_specs.md` §7 and dispatches generically — there is no
per-import table, so adding a new extern never requires touching the
translator.

### Zig

```zig
extern "env" fn @"UnityEngineDebug.__Log__SystemString__SystemVoid"(
    ptr: [*]const u8,
    len: usize,
) void;
```

Zig's raw-identifier syntax (`@"..."`) lets the import name contain
dots and other characters that aren't valid identifiers.

### Rust

```rust
#[link(wasm_import_module = "env")]
unsafe extern "C" {
    #[link_name = "UnityEngineDebug.__Log__SystemString__SystemVoid"]
    fn debug_log(ptr: *const u8, len: usize);
}
```

A few things to note:

- `unsafe extern "C"` (Rust 2024 syntax) is required — `extern "C"`
  alone now warns/errors in 2024 edition.
- `#[link(wasm_import_module = "env")]` sets the WASM import module
  for the entire block; this is what the translator's signature
  matcher keys on alongside the per-function `link_name`.
- Use the matching C calling convention (`extern "C"`) — Rust's
  default ABI may pass aggregates through hidden pointers and break
  the parser's idea of "two-arg `(ptr, len)` extern".

### Strings

`SystemString`-typed parameters in the Udon signature are
auto-marshalled by the translator from a `(ptr: i32, len: i32)` pair
on the WASM side. So a Zig `[]const u8` slice or a Rust
`(*const u8, usize)` pair both work — pass the pointer first, length
second.

### The `udon.self` import trick

`udon.self` (returning the receiver `UnityEngineTransform`) is a
Udon-only singleton with no real WASM-side function body. It is bound
through `__udon_meta.fields.self` with `source.kind = "import"` so the
translator turns calls to it into a pure read of the `__G__self` data
slot rather than a real EXTERN. Declare it on the producer side as a
normal nullary import:

```rust
#[link(wasm_import_module = "env")]
unsafe extern "C" {
    #[link_name = "udon.self"]
    fn udon_self() -> i32;
}
```

```jsonc
"fields": {
  "self": {
    "source": { "kind": "import", "module": "env", "name": "udon.self" },
    "udonName": "__G__self",
    "type": "transform",
    "default": "this"
  }
}
```

See `docs/spec_host_import_conversion.md` for the full calling
convention (instance methods take the receiver as the first WASM arg
when the WASM arity is one greater than the signature's arg-list
length).

---

## 5. State and `__udon_meta.fields`

`__udon_meta.fields[*].source.kind` currently has two implementations
in the translator:

| `kind`   | What it binds to                                                         | Status                  |
|----------|--------------------------------------------------------------------------|-------------------------|
| `global` | A WASM **global** (mutable or immutable). Resolves via the export table. | Implemented             |
| `import` | A WASM **function import** (e.g. `udon.self`); see §4 above.             | Implemented             |
| `symbol` | A symbol-name pointing into linear memory.                               | Documented, not yet implemented |

Practical consequence: only state that lives in a true WASM global can
be exposed to Udon as a field today. Because **MVP forbids mutable
globals** (§1), this means:

- **Zig** can place tweakable scalars (`f32`, `i32`, …) as `export var`
  globals — these become exported WASM globals and `kind: "global"`
  picks them up.
- **Rust** cannot. `static mut` lives in linear memory; only the address
  is an exported global, which is not what `kind: "global"` resolves
  to. Until `kind: "symbol"` is implemented, Rust producers should
  keep mutable state private to the wasm side and expose only
  `udon.self`-style imports as fields.

If you need Inspector-tunable parameters today, write the relevant
example in Zig.

---

## 6. `__udon_meta` discovery contract

The translator finds the JSON blob through two exports:

| Export name        | Meaning                                  | WASM type                       |
|--------------------|------------------------------------------|---------------------------------|
| `__udon_meta_ptr`  | Linear-memory byte offset of the JSON    | `i32` (or func returning `i32`) |
| `__udon_meta_len`  | Byte length of the JSON                  | `i32` (or func returning `i32`) |

Both are required; if either is missing, the translator silently
treats the module as having no metadata and falls back to defaults.

### What "constant" means

Both locators are evaluated by `src/wasm/const_eval.zig`'s
`evalExportedI32`, which is a deliberately tiny constant evaluator.
The translator never executes WASM. It accepts only:

1. An **exported global** whose init expression is a single `i32.const N`.
2. An **exported nullary function** whose body is exactly one of:
   - `i32.const N`
   - `global.get G`, where `G` is *not* an imported global and `G`'s
     init expression is itself a single `i32.const N` (one hop only).

Everything else returns `error.NonConstMetaLocator`:
multi-instruction bodies, arithmetic, `local.get`, computed addresses,
chained `global.get`, `global.get` of an imported global.

### Producer recipes

Both languages emit a function whose body collapses to a single
`i32.const` after optimization:

```zig
// Zig (ReleaseSmall)
const udon_meta_json = \\{ "version": 1, ... };

export fn __udon_meta_ptr() [*]const u8 { return udon_meta_json.ptr; }
export fn __udon_meta_len() u32 { return @intCast(udon_meta_json.len); }
```

```rust
// Rust (release profile from §2)
const UDON_META_JSON: &[u8] = br#"{ "version": 1, ... }"#;

#[unsafe(no_mangle)]
pub extern "C" fn __udon_meta_ptr() -> *const u8 { UDON_META_JSON.as_ptr() }

#[unsafe(no_mangle)]
pub extern "C" fn __udon_meta_len() -> u32 { UDON_META_JSON.len() as u32 }
```

For raw WAT, two exported immutable globals are simpler:

```wat
(global (export "__udon_meta_ptr") i32 (i32.const 1024))
(global (export "__udon_meta_len") i32 (i32.const 187))
(data  (i32.const 1024) "{ \"version\": 1, ... }")
```

### Data segment placement

Once `(ptr, len)` is known, the byte range must lie **fully inside one
data segment** whose offset itself constant-folds. Splitting the JSON
across segments returns `error.MetaSpansMultipleSegments`. A single
`static`/`const` byte literal is the safe choice.

### Common errors

| Error                          | Cause                                                                                                |
|--------------------------------|------------------------------------------------------------------------------------------------------|
| `NonConstMetaLocator`          | Locator function body is more than one instruction, or uses an unsupported op. Disassemble with `wasm-tools print` and confirm. |
| `MetaSpansMultipleSegments`    | The JSON blob landed across a data-segment boundary. Move into a single literal.                     |
| `MetaRangeOutOfData`           | `__udon_meta_ptr` resolved to an address no data segment covers. Often the slice was eliminated as dead code — make sure the meta exports are reachable. |
| Translator silently uses defaults | One of `__udon_meta_ptr` / `_len` is missing from the exports. Discovery is all-or-nothing.       |

---

## 7. Recursion: opt-in via `options.recursion`

Udon has no call stack — the translator's RAC-based ABI keeps each
function's parameters/locals in flat heap slots. That means a function
that calls itself (directly or transitively) overwrites its own state.

Recursive functions therefore need an explicit opt-in so the translator
emits prologue/epilogue spill of P / L / R / RA onto the synthesized
`__call_stack__`. Set in your `__udon_meta`:

```jsonc
"options": {
  "recursion": "stack"
}
```

Detection is Tarjan-SCC based across the whole call graph, so opting
in is binary — once enabled, all recursive (or mutually recursive)
functions get the spill. See `src/translator/recursion.zig` for the
analysis and `examples/wasm-bench/main.zig` (`factorial`/`fib`) plus
`examples/wasm-bench-rs/src/lib.rs` for the matching producer-side
test.

---

## 8. Linear memory sizing

`__udon_meta.options.memory.{initialPages, maxPages, udonName}`
controls the chunked-array layout described in
`docs/spec_linear_memory.md`. A few non-obvious behaviors:

- **`maxPages` is a *floor*, not a hard ceiling.** The translator
  computes the highest page any data segment occupies (rounded up
  from `(offset + len)`) and clamps `maxPages` and `initialPages` up
  to that value. If your meta says `maxPages: 4` but the linker laid
  out the binary with data extending into page 16, the emitted
  `_memory_max_pages` literal will read 17. This is intentional —
  undercounting cannot produce broken bytecode this way.
- The clamp also applies to `initialPages` so `emitMemoryInit`
  unrolls the right number of chunk allocations.
- Set `udonName` (e.g. `"_memory"`) when you want the outer
  `SystemObjectArray` and its companion scalars exported under a
  predictable name.

If you don't know how much memory you need, a generous `maxPages`
costs nothing at translate time (only `_memory_max_pages` literal
size) and avoids surprises.

---

## 9. Build & translate pipeline

For the Rust crates in this repo:

```sh
# 1. Build the wasm
cargo build --release
# → target/wasm32v1-none/release/<name>_underscored.wasm

# 2. Build / re-build the translator if needed
zig build

# 3. Translate
./zig-out/bin/wasdon_zig.exe translate \
    target/wasm32v1-none/release/<name>_underscored.wasm \
    -o zig-out/wasm/<name>.uasm
```

For the Zig examples, `zig build wasm-example` and
`zig build udon-orbit-example` (defined in `build.zig`) compile and
install the wasm into `zig-out/wasm/`, and copy the bench fixture
into the test data directories so the integration tests can
`@embedFile` it.

The translator CLI accepts `--mem-oob-diagnostics` to instrument every
memory op with a unique site id and the effective byte address.
Useful when a generated program hits an OOB trap and the bare
`page=P; max=M` log line isn't enough to localize it.

---

## 10. Verifying the output

A quick sanity check on the produced `.uasm`:

```sh
# Event labels you declared in __udon_meta.functions should all appear
grep -nE "^\s*\.export _start|_update|_interact" output.uasm

# The data section header confirms memory sizing was honored
head -30 output.uasm
```

Ground-truth verification is "does it run on the Udon VM" — the CI
cannot do that. The translator's responsibility ends at "emit a
structurally spec-conformant Udon Assembly program."

---

## Quick checklist before opening a PR

- [ ] Toolchain pinned to MVP (`cpu_model = .mvp` for Zig,
      `wasm32v1-none` for Rust).
- [ ] Release profile gives `__udon_meta_ptr/_len` single-instruction
      bodies (`opt-level=z`, `lto=true`, `codegen-units=1`).
- [ ] Every Udon EXTERN is declared with the verbatim signature name
      from `docs/udon_nodes.txt`.
- [ ] Mutable state matches the field-source rules in §5 (Zig: WASM
      globals; Rust: keep private until `kind: "symbol"` lands).
- [ ] `options.recursion = "stack"` set if any function recurses
      (directly or transitively).
- [ ] `options.memory.maxPages` is at least as large as you actually
      need; underestimates are silently floored up but
      overestimates cost almost nothing.
- [ ] Translator round-trip checked: `cargo build --release` →
      `wasdon_zig translate ... -o foo.uasm` succeeds, and the
      expected `.export _start`/`_update`/`_interact` labels appear
      in the output.

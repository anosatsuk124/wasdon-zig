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

The translator is a Core 1 / MVP parser. It rejects most post-MVP
opcodes (the rest of the `0xFC` prefix space beyond the supported
bulk-memory / saturating-truncation ops, multi-value results,
reference types, etc.) with `UnknownOpcode` or related parse errors.

A handful of post-MVP proposals are accepted as deliberate, opt-in
extensions (the parser **and** the translator both implement them
end-to-end):

- **`mutable-globals`** — see "Mutable globals across the boundary"
  below and `docs/spec_variable_conversion.md` ("Mutability").
- **Sign-extension ops** (`i32.extend8_s`, `i32.extend16_s`,
  `i64.extend8_s`, `i64.extend16_s`, `i64.extend32_s`) — see
  `docs/spec_numeric_instruction_lowering.md` §4.
- **`memory.copy`** (bulk-memory, opcode `0xFC 0x0A`) — overlap-safe
  byte-loop lowering, see `docs/spec_linear_memory.md`
  §"memory.copy lowering" and `examples/post-mvp/memory-copy/`.
- **`memory.fill`** (bulk-memory, opcode `0xFC 0x0B`) — forward
  byte-store loop, see `docs/spec_linear_memory.md`
  §"memory.fill lowering" and `examples/post-mvp/memory-fill/`.
- **Passive data segments + DataCount section** (bulk-memory) — Data
  section mode `0x01` (passive) and the dedicated `DataCount` binary
  section (id `12`, ordered between Element and Code per spec); each
  passive segment is materialised as a `__G__data_seg_<idx>__bytes`
  / `__G__data_seg_<idx>__dropped` field pair. See
  `docs/spec_linear_memory.md` §"Passive data segments",
  `docs/w3c_wasm_binary_format_note.md` §"DataCount ordering
  exception" and `examples/post-mvp/bulk-memory-passive/`.
- **`memory.init`** (bulk-memory, opcode `0xFC 0x08`) — per-byte copy
  loop from a passive segment into linear memory, with dropped-flag
  and bounds checks. See `docs/spec_linear_memory.md`
  §"memory.init lowering" and `examples/post-mvp/memory-init/`.
- **`data.drop`** (bulk-memory, opcode `0xFC 0x09`) — flips the
  passive segment's `__dropped` flag (no-op for active segments per
  WASM 2.0). See `docs/spec_linear_memory.md` §"data.drop lowering"
  and `examples/post-mvp/data-drop/`.
- **`reference-types` (decoder subset)** — `funcref` value-type byte
  (`0x70`) is accepted by the value-type decoder, **but** any
  appearance in a function param/result, local, or global type
  position is rejected with `FuncrefValueTypeNotYetSupported`. Today
  the only practical use is enabling toolchains that emit the
  generalised `call_indirect` encoding below.
- **`call_indirect` with explicit `table_idx`** — the trailing byte
  is decoded as a `uleb128` table index instead of a reserved zero;
  the lowering still requires `table_idx == 0`. Other values are
  rejected with `MultiTableNotYetSupported`. See
  `docs/spec_call_return_conversion.md` §7.5 and
  `examples/post-mvp/reference-types-funcref/`.
- **`nontrapping-fptoint`** — saturating float-to-int family
  (`i32.trunc_sat_f32_s/u`, `i32.trunc_sat_f64_s/u`,
  `i64.trunc_sat_f32_s/u`, `i64.trunc_sat_f64_s/u`, opcodes
  `0xFC 0x00`–`0xFC 0x07`) — lowered through two shared NaN /
  low-clamp / high-clamp / SystemConvert helper subroutines per
  output bit width; see `docs/spec_numeric_instruction_lowering.md`
  §5 and `examples/post-mvp/nontrapping-fptoint/`.

You **must** pin your toolchain to MVP-only output:

| Toolchain | What to do                                                          |
|-----------|---------------------------------------------------------------------|
| Zig       | `cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp }` on a `wasm32-freestanding` target. The default `generic` model enables `multivalue` (the parser still refuses this), in addition to the proposals listed above as accepted post-MVP extensions (`mutable-globals`, `sign-ext`, the full `bulk-memory` op set — `memory.copy` / `memory.fill` / `memory.init` / `data.drop` plus passive-segment / DataCount handling, `nontrapping-fptoint`, and the `reference-types` decoder subset described above) flow through end-to-end. See `build.zig` in this repo for the canonical setup. |
| Rust      | Use the `wasm32v1-none` target — it is the official "WASM 1.0 / MVP only" target and disables every post-MVP feature by default. `wasm32-unknown-unknown` will *not* work without aggressive `-C target-feature=-…` flags, and even then is a moving target. |
| WAT/wasm-tools | Hand-author or process with `wasm-tools` / `wabt`. The bulk-memory and reference-types proposals are off by default; opt them in as described in "wat2wasm flags for post-MVP examples" below. |

### wat2wasm flags for post-MVP examples

Hand-authored WAT examples that exercise the post-MVP extensions
above must opt the relevant proposals in at the `wat2wasm` (WABT)
command line, because WABT defaults to a strict MVP encoder. The
flags the translator's example fixtures rely on:

```sh
# Bulk-memory: passive data segments, DataCount, memory.init, data.drop
# (memory.copy / memory.fill also live under this flag)
wat2wasm --enable-bulk-memory example.wat -o example.wasm

# reference-types: funcref value byte and call_indirect with explicit
# table index (varuint table_idx instead of the reserved 0x00)
wat2wasm --enable-reference-types example.wat -o example.wasm

# Combined — most post-MVP examples enable both because reference-types
# implies funcref tables, which in turn pair naturally with bulk-memory
# segment management.
wat2wasm --enable-bulk-memory --enable-reference-types example.wat -o example.wasm
```

Without `--enable-bulk-memory`, WABT will refuse the `(data passive
...)` syntax and the `memory.init` / `data.drop` instructions; without
`--enable-reference-types`, it will reject the explicit-table form of
`(call_indirect (type ...) <tableidx>)` and treat `funcref` value
types as unknown. The flags only affect the encoder — they do **not**
add unsupported features behind your back, so passing them while
writing strict MVP WAT is harmless.

The `examples/post-mvp/` fixtures the translator ships have their
exact `wat2wasm` invocation written in their per-example `README.md`.

### Mutable globals across the boundary

Mutable WASM globals are accepted (the post-MVP `mutable-globals`
proposal is opted in deliberately — see the list of accepted post-MVP
extensions above for the full set). Both module-defined and imported mutable globals lower
to ordinary mutable Udon data fields, because Udon has no `const`
concept for fields. The translator does not filter on the `mut` bit.

Practical consequence for shared host↔WASM state: a host-supplied
mutable global import (e.g. `env.timer_ms`) is observed as follows:

1. The translator allocates a backing Udon field for the import
   (named per `__udon_meta.fields[*].udonName` when matched, otherwise
   `__G__imp_<module>_<name>`).
2. The host writes to that field with the established Udon
   `SetVariable` mechanism.
3. The WASM module observes those writes through normal `global.get`.

The Rust `wasm32v1-none` target still emits `static mut` into linear
memory rather than as WASM globals; if you want host-visible state from
Rust today, expose it through this mutable-globals path or wait for the
`kind: "symbol"` field source in `__udon_meta` (see
[§5](#5-state--__udon_metafields)). A worked WAT example lives at
`examples/post-mvp/mutable-globals/`.

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

The release profile is shaped to match the translator's MVP-only input:

- `opt-level = "z"` and `lto = true` keep the binary small and let the
  Rust optimizer collapse trivial helpers, but they are no longer
  load-bearing for `__udon_meta` discovery — the metadata is supplied
  as a sidecar JSON file (see [§6](#6-__udon_meta-sidecar-json)).
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

### Using `alloc` (`Vec`, `Box`, `String`, `BTreeMap`)

`wasm32v1-none` ships no global allocator, but the translator does not
forbid heap-using Rust code. Register a `#[global_allocator]` of your
own and `extern crate alloc;`, and the standard heap types come back:

```rust
extern crate alloc;
use alloc::vec::Vec;

const ARENA_SIZE: usize = 256 * 1024;
static mut ARENA: [u8; ARENA_SIZE] = [0; ARENA_SIZE];
static mut BUMP: usize = 0;

struct BumpAlloc;
unsafe impl core::alloc::GlobalAlloc for BumpAlloc {
    unsafe fn alloc(&self, layout: core::alloc::Layout) -> *mut u8 {
        let cur = unsafe { *(&raw const BUMP) };
        let aligned = (cur + layout.align() - 1) & !(layout.align() - 1);
        let new = aligned + layout.size();
        if new > ARENA_SIZE { return core::ptr::null_mut(); }
        unsafe { *(&raw mut BUMP) = new; }
        unsafe { (&raw mut ARENA as *mut u8).add(aligned) }
    }
    unsafe fn dealloc(&self, _: *mut u8, _: core::alloc::Layout) {}
}

#[global_allocator]
static GLOBAL: BumpAlloc = BumpAlloc;
```

A `static mut` arena is the smallest MVP-clean option:

- It lives in the data section, so the allocator never has to call
  `memory.grow` on the hot path. The hot path stays trivially
  MVP-only.
- `dealloc` as a no-op is allowed by `GlobalAlloc`. Reset the bump
  pointer at the top of every event entrypoint to keep memory bounded
  across Udon's per-event 10 s budget.
- `Vec` realloc still copies. On `wasm32v1-none` today, Rust's
  `core::ptr::copy_nonoverlapping` lowers to a compiler-builtins
  software memcpy loop. The translator now also accepts the post-MVP
  `memory.copy` and `memory.fill` opcodes directly (overlap-safe byte
  loop and forward byte-store loop respectively, see
  `docs/spec_linear_memory.md`), so a producer that *does* emit
  either — for example `wasm-opt -O` rewriting the software loops into
  one bulk-memory op — is fine. Both bulk-memory ops are now accepted
  with no extra producer-side work required.

See `examples/wasm-bench-alloc-rs` for a worked end-to-end example
covering `Vec`, `Box`, `String`, nested `Vec<Vec<_>>`, `BTreeMap`,
and a direct `memory.grow` probe.

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
be exposed to Udon as a field today. The translator opts in to the
post-MVP `mutable-globals` proposal (see §1), so both mutable and
immutable WASM globals are valid sources:

- **Zig** can place tweakable scalars (`f32`, `i32`, …) as `export var`
  globals — these become exported WASM globals (immutable in MVP-mode
  builds, mutable when authored as such in WAT) and `kind: "global"`
  picks them up.
- **Rust** still emits `static mut` into linear memory rather than as a
  WASM global. Until `kind: "symbol"` is implemented, Rust producers
  should keep mutable state private to the wasm side and expose only
  `udon.self`-style imports — or hand-author the boundary with the
  WAT-level mutable-globals pattern in
  `examples/post-mvp/mutable-globals/`.

If you need Inspector-tunable parameters today, write the relevant
example in Zig (or use a hand-rolled WAT shim).

---

## 6. `__udon_meta` sidecar JSON

`__udon_meta` is supplied as a **sidecar JSON file** that lives next to the
`.wasm` input. The Wasm binary itself contains nothing related to the
metadata — no exports, no data segments, no globals are reserved for it.

| Path convention                          | Where it lives                                |
|------------------------------------------|-----------------------------------------------|
| `<wasm-stem>.udon_meta.json`             | Same directory as the `.wasm`, auto-discovered |
| `--meta <path>`                          | Anywhere; takes precedence over auto-discovery |

If neither is present, the translator silently treats the module as having
no metadata and falls back to defaults.

### CLI

```sh
# auto-discover bench.udon_meta.json next to bench.wasm
wasdon_zig translate path/to/bench.wasm -o bench.uasm

# explicit path
wasdon_zig translate path/to/bench.wasm \
    --meta path/elsewhere/bench.udon_meta.json -o bench.uasm
```

### Library

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

### Producer recipes

Producers do not need to do anything beyond writing the sidecar JSON file.
Earlier revisions of this guide required an `__udon_meta_ptr` /
`__udon_meta_len` export pair plus an in-binary data segment; that contract
has been retired because it had brittle producer-side requirements (LTO +
`opt-level=z` + hand-tracked WAT offsets) and the data was never actually
read at runtime.

Recommended layout (Rust crate):

```text
examples/wasm-bench-rs/
├─ Cargo.toml
├─ wasm_bench_rs.udon_meta.json   # commit this
└─ src/lib.rs
```

Recommended layout (Zig source):

```text
examples/wasm-bench/
├─ main.zig
└─ bench.udon_meta.json           # commit this
```

The `__udon_meta.functions` keys still drive event-label mapping
(`_start` / `_update` / `_interact` / custom) and the `__udon_meta.fields`
keys still drive Udon data-section field naming — only the *delivery
mechanism* has moved out of the binary.

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

## WASI Preview 1 subset

The translator recognises the import module `wasi_snapshot_preview1`. The
implemented MVP subset (`docs/spec_wasi_preview_1.md` §2.1) covers
`proc_exit`, `fd_write`, `fd_read`, `environ_get` / `environ_sizes_get`,
`args_get` / `args_sizes_get`, `fd_close`, `fd_seek`, `fd_fdstat_get`. Every
other WASI function is recognised but lowered as an `errno.nosys` (52)
stub. Strict mode (`__udon_meta.options.strict = true`) elevates an
unrecognised WASI name to a translate-time error.

Producer-side pitfalls specific to WASI:

- **`fd_write` is the only sink.** `println!` / `eprintln!` / Zig's stdout
  writer reach `Debug.Log`; everything else either silently no-ops
  (`fd_close`) or reports `errno.spipe` (`fd_seek`). Do not depend on a
  `fd_write` round trip — `*nwritten` reflects only what the translator
  consumed, not what the host actually displayed.
- **No filesystem, no sockets.** `path_*`, `sock_*`, `fd_pread`, etc.
  return `errno.nosys`. A program that conditionally reads a file in
  `_start` will still translate, but the runtime path will surface the
  `nosys` errno; check for it in producer code if you cannot guarantee
  the call sites are dead.
- **`std::process::exit(n)` works.** It lowers to `proc_exit(n)`, which
  emits the Udon program-end sentinel `JUMP, 0xFFFFFFFC`. The exit code
  is currently dropped — see `spec_wasi_preview_1.md` §4.1.
- **Override the log sink** through `__udon_meta.wasi.stdout_extern` /
  `wasi.stderr_extern` if your scene uses a `Text` component or VRChat
  ChatBox sink instead of `Debug.Log`. Use the verbatim Udon signature.
- **wasi-libc static initialisers**. `_start` typically references
  `fd_close` / `fd_seek` / `environ_*` even in a trivial `println!`
  program. The translator emits the documented stubs for all of these,
  so they link cleanly without a producer-side workaround.

A worked example is `examples/wasi-hello/` (hand-rolled WAT plus a sidecar
`wasi_hello.udon_meta.json`). See its README for the `wat2wasm` build
incantation and the verified `wasm-objdump -x` output.

### WASI Rust with std (`wasm32-wasip1`)

`examples/wasi-hello/` is hand-written WAT and `examples/wasm-bench-rs/`
uses `wasm32v1-none` (no WASI). For real Rust crates that need
`std` — embedded scripting engines, parsers, anything that allocates —
target **`wasm32-wasip1`** instead. `examples/rhai-bench/` is the
canonical worked example.

Practical notes:

- **Per-package target override.** The workspace-wide
  `.cargo/config.toml` pins `wasm32v1-none`, so a `wasm32-wasip1`
  example must ship its own `.cargo/config.toml` to override the
  default:

  ```toml
  # examples/<name>/.cargo/config.toml
  [build]
  target = "wasm32-wasip1"
  rustflags = [
      "-C", "target-feature=-multivalue,-reference-types,-simd128",
  ]
  ```

  Cargo picks the closest config relative to the cwd, so a `cargo build`
  invoked from inside the package directory uses this file. From the
  workspace root, pass `--target wasm32-wasip1 -p <name>` explicitly.

- **Strip post-MVP wasm features the translator does not yet handle.**
  `wasm32-wasip1` enables `bulk-memory`, `mutable-globals`, `sign-ext`,
  and `nontrapping-fptoint` by default — all already supported by the
  translator. **`multivalue`, `reference-types` (beyond the funcref
  decoder subset), and `simd128`** are not, so disable them via
  `RUSTFLAGS` / per-package `rustflags` as above. Without that, the
  parser will reject the binary with an `UnknownOpcode`-class error.

- **Crate type is `bin`, not `cdylib`.** wasi-libc generates `_start`
  for binary crates. A `cdylib` does not export `_start`, so
  `__udon_meta.functions.start.source.export = "_start"` would not
  resolve.

  ```toml
  # examples/<name>/Cargo.toml
  [[bin]]
  name = "<name>_underscored"
  path = "src/main.rs"
  ```

- **Output path is the workspace target dir, not per-package.** Cargo
  workspaces share `<workspace-root>/target/<triple>/release/<name>.wasm`
  regardless of where you invoked `cargo build`. The committed
  `<name>.udon_meta.json` lives in the example source directory; pass
  it to the translator with `--meta`, since the auto-discovery path
  next to the `.wasm` lands inside the gitignored `target/` tree.

- **WASI calls a real Rust binary actually emits.** Beyond the obvious
  `fd_write` / `proc_exit`, wasi-libc's `_start` glue references the
  full preopen / fdstat / environ stub set during static
  initialisation; the translator stubs every name in
  `lower_wasi.zig`'s `deferred_names` table to `errno.nosys` so the
  binary still links. If your code only uses `println!`, `Vec`, etc.,
  you should not see anything beyond what `examples/rhai-bench/`'s
  README's "Expected WASI imports" table lists.

### WASI C with wasi-sdk (mruby and friends)

`examples/mruby-bench/` is the worked example for cross-compiling a C
project (mruby 3.3.0) to `wasm32-wasi` via the wasi-sdk clang
toolchain. The recipe applies to anything that has a `Makefile` /
`CMake` / autoconf build and ships a static library you can link
against `wasi-libc`.

Key points:

- **Toolchain prerequisites are not Rust ones.** wasi-sdk is a
  separate ~150 MB install (LLVM + wasi-libc + wasi-sysroot). Set
  `WASI_SDK_PATH` to its install root. The build also needs whatever
  the upstream project requires — for mruby that means Ruby + Rake on
  the build machine to run `mrbc` and the gembox plumbing.

- **Pin the embedded VM's version.** A pinned tag (e.g. `MRUBY_TAG :=
  3.3.0` in the Makefile) plus `git clone --depth 1 --branch
  $(MRUBY_TAG)` keeps the cross-build reproducible. Vendored sources
  go under `vendor/<project>/` and are gitignored — the example only
  commits the `Makefile`, the cross-build config, the driver, and the
  sidecar JSON.

- **Embed scripts as bytecode, never read from disk.** mruby's
  preferred trick is `mrbc -B <symbol> -o build/script.c script.rb`,
  which emits a C array that links into the final binary. Equivalent
  patterns exist for other VMs (Lua's `luac` + `xxd -i`, Wren's
  `wrenc`, …). Reading the script from a real path drags
  `path_open` / `fd_filestat_get` into the import set, which the
  translator stubs to `nosys`. The script then fails to load.

- **Curate the gembox / feature flags so no IO gem leaks in.** mruby's
  `default` gembox includes `mruby-io` and `mruby-bin-mruby` which
  themselves call `path_open` / `fd_pread`. The mruby-bench
  `build_config.rb` lists the safe gem set explicitly. For other
  projects, audit the link-time symbol set with `wasm-ld --print-map`
  or grep the produced `.wasm` for `path_` / `sock_` / `proc_raise`.

- **Pin the mruby `MRuby::CrossBuild` toolchain to wasi-sdk's
  `clang` and `llvm-ar`.** Default `gcc` will not produce wasm.
  `cc.flags` should include `--target=wasm32-wasi
  --sysroot=$(WASI_SDK_PATH)/share/wasi-sysroot`, plus whatever
  size/perf knobs you want (`-O2`, `-DMRB_NO_PRESYM`, …).

- **wasi-sdk version skew is the most common build failure.** Track
  the wasi-sdk version that produced your last working build in the
  README. Major versions occasionally rename `wasi-sysroot` paths or
  retire predefined macros (e.g. `__wasi__` vs `__wasm32__`).

## Quick checklist before opening a PR

- [ ] Toolchain pinned to MVP (`cpu_model = .mvp` for Zig,
      `wasm32v1-none` for Rust).
- [ ] `<wasm-stem>.udon_meta.json` sidecar committed alongside the
      producer source (or `--meta` path documented in your
      tooling).
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
      `wasdon_zig translate ... -o foo.uasm` succeeds (sidecar JSON
      auto-discovered or passed via `--meta`), and the expected
      `.export _start`/`_update`/`_interact` labels appear in the
      output.

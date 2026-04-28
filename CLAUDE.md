# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project goal

`wasdon-zig` is a binary translator written in Zig that parses a WebAssembly binary and lowers it to **Udon Assembly** (the textual form executed by VRChat's Udon VM). The current source tree is a freshly scaffolded Zig project — almost all of the load-bearing material lives in `docs/`, which describes how the eventual translator must behave.

Read the `docs/` specs before designing or implementing any translation logic; the WASM → Udon mapping is non-trivial and the Udon VM has unusual constraints (see "Udon constraints that drive design" below).

## Toolchain & common commands

- Zig is pinned via `mise` (`mise.toml` → `zig = "latest"`). `build.zig.zon` requires `minimum_zig_version = "0.16.0"`.
- Build the executable: `zig build`
- Run the executable (pass program args after `--`): `zig build run -- <args>`
- Run all tests (both `mod` tests in `src/root.zig` and `exe` tests in `src/main.zig` — they run in parallel): `zig build test`
- Fuzz the example test: `zig build test --fuzz`
- There is no separate lint step; rely on `zig fmt` / the compiler.

## Module layout

The build graph in `build.zig` defines two modules:

- `src/root.zig` — the public library module, exposed to consumers as `@import("wasdon_zig")`. Anything intended for reuse (parser, IR, emitter) must be re-exported here.
- `src/main.zig` — the CLI executable. It imports `wasdon_zig` and is the only place that touches `std.process.Init`/stdio.

Tests live alongside code as `test "..." { ... }` blocks; `zig build test` builds two test executables (one per module) because Zig tests one module at a time.

## Udon constraints that drive design

These are the non-obvious target-language properties that shape every translation decision. They are spelled out in `docs/udon_specs.md` (the authoritative Udon Assembly reference) but are easy to miss:

- **No local variables.** Every Udon variable is a field on the UdonBehaviour. WASM locals must be flattened into globals using the naming scheme in `docs/spec_variable_conversion.md` (`__{function_name}_L{local_index}__name` for locals, `__G__name` for globals).
- **No call/return, no subroutines.** Only `JUMP`, `JUMP_INDIRECT`, and `JUMP_IF_FALSE` exist. Any function-call ABI must be synthesized on top of these (and recursion must be designed deliberately because there are no locals to save).
- **External calls go through `EXTERN`** with .NET method signatures encoded as "Udon type names" (namespace+type concatenated with no `.`, generics inlined, arrays suffixed with `Array`).
- **No raw byte memory, no resizable arrays.** WASM linear memory cannot be represented natively. Per `docs/spec_linear_memory.md`, model it as a two-level array: an outer `SystemObjectArray` sized to `maxPages`, whose slots hold inner `SystemUInt32Array` chunks of 16384 words (one WASM page each). Byte-level loads/stores are synthesized with shift/mask over words (little-endian). `memory.grow` allocates new inner chunks and stores them into the outer array — existing memory is never copied. A scalar `__G__memory_size_pages` tracks the currently committed page count.
- **Translator-time metadata via `__udon_meta`.** Per `docs/spec_udonmeta_conversion.md`, the WASM module may export a static UTF-8 JSON blob named `__udon_meta` describing how globals/symbols become data-section fields, how exported functions map to Udon event labels (`_start`, `_update`, `_interact`, custom), sync modes, and translator options. The translator must look for this blob and, if absent, fall back to defaults — it is **not** read at runtime.
- **`__udon_meta` discovery contract.** The translator finds the blob through two exports — `__udon_meta_ptr` (linear-memory address of the JSON bytes) and `__udon_meta_len` (length in bytes). Both are resolved by `src/wasm/const_eval.zig`'s `evalExportedI32`, which only accepts (a) an exported global whose init expression is a single `i32.const N`, or (b) an exported nullary `i32`-returning function whose body is exactly one `i32.const N` or one `global.get G` (where `G`'s init folds the same way). Anything else — multi-instruction bodies, arithmetic, `local.get`, returning a slice through helper code — fails with `NonConstMetaLocator`. Producers (Zig, Rust, hand-rolled WAT) must therefore emit these locators as compile-time constants; for Rust on `wasm32v1-none` this requires `-C opt-level=z` + `lto=true` + `codegen-units=1` so the optimizer collapses `SLICE.as_ptr()` / `SLICE.len()` to a single `i32.const`. Once located, the byte range must lie fully inside one data segment whose offset itself constant-folds — spanning two segments returns `MetaSpansMultipleSegments`.

## Documentation policy

Whenever a new discovery, behavior, spec interpretation, or feature is introduced, you **must** add or update a corresponding document under `docs/`. Treat code changes and documentation updates as a single unit of work — neither is "done" without the other.

- **All documentation under `docs/` (and any new doc files added to the repo) must be written in English.** This applies to spec docs, design notes, and producer-side guides regardless of the language used in chat. Do not commit non-English prose into `docs/` or other repo-tracked documentation.
- New WASM instruction handling or Udon constraint behavior discovered → update the relevant existing spec (`docs/spec_*.md` / `docs/udon_specs.md`) or add a new one.
- New feature or translation pass added → record the design intent, inputs/outputs, and known limitations under `docs/`.
- Reproducible producer-side pitfall (Rust/Zig/WAT) discovered → append it to the producer-facing guide `docs/producer_guide.md` (covers toolchain pinning, `no_std` skeleton, extern declarations, `__udon_meta` discovery, recursion opt-in, memory sizing, and the build → translate pipeline).

When you add a new doc, also reflect it in the "Spec documents" list in this `CLAUDE.md` if it belongs there.

## `.gitignore` policy

The repo's `.gitignore` is for **project-level build artifacts and generated fixtures only** — things every checkout of this repo would produce regardless of who is working on it (e.g. `zig-out/`, `.zig-cache/`, `target/`, generated `testdata/`).

Do **not** add user/environment-specific entries that are the contributor's own responsibility. Those belong in the user's global gitignore (`core.excludesFile`), not in this repo. Examples to keep out of `.gitignore`:

- OS metadata: `.DS_Store`, `Thumbs.db`, `Desktop.ini`
- Editor/IDE state: `.vscode/`, `.idea/`, `*.swp`, `.history/`
- Personal tooling state: `.claude/`, `.tmp/`, ad-hoc scratch files (`*.uasm` left in the repo root, one-off `*.wat`, etc.)
- Local secrets / credentials

Rule of thumb: if a file appears only because of *your* tool / editor / OS, it's user-responsibility. If it appears because *anyone* who builds this project produces it, it's project-responsibility and may be added.

## Spec documents (read these before designing translation passes)

- `docs/udon_specs.md` — Udon Assembly syntax, type-name rules, instruction set, EXTERN semantics. The target language reference.
- `docs/spec_variable_conversion.md` — naming scheme for flattening WASM locals/globals into Udon's flat field namespace.
- `docs/spec_linear_memory.md` — strategy for representing WASM linear memory as a `SystemObjectArray`.
- `docs/spec_numeric_instruction_lowering.md` — central reference for WASM numeric instruction lowering (MVP arithmetic/comparison via `lower_numeric.zig`, plus post-MVP sign-extension and saturating truncation handlers).
- `docs/spec_udonmeta_conversion.md` — schema and resolution rules for the `__udon_meta` JSON blob (`version`, `behaviour`, `fields`, `functions`, `options`).
- `docs/producer_guide.md` — end-to-end producer-side guide for writing WASM the translator accepts: MVP toolchain pinning (Zig + Rust `wasm32v1-none`), Cargo workspace layout, `no_std` skeleton, host-import declarations and the `udon.self` import-binding trick, mutable-state limitations, `__udon_meta` discovery contract, recursion opt-in, linear-memory sizing, build → translate pipeline, and a pre-PR checklist.

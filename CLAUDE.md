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

## Spec documents (read these before designing translation passes)

- `docs/udon_specs.md` — Udon Assembly syntax, type-name rules, instruction set, EXTERN semantics. The target language reference.
- `docs/spec_variable_conversion.md` — naming scheme for flattening WASM locals/globals into Udon's flat field namespace.
- `docs/spec_linear_memory.md` — strategy for representing WASM linear memory as a `SystemObjectArray`.
- `docs/spec_udonmeta_conversion.md` — schema and resolution rules for the `__udon_meta` JSON blob (`version`, `behaviour`, `fields`, `functions`, `options`).

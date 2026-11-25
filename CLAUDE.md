# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project goal

`wasdon-zig` is a translator written in Zig that parses a WebAssembly binary and lowers it to **Udon Assembly** (the textual form executed by VRChat's Udon VM). It also contains an Udon Assembly checker and an Udon VM emulator, which the tests use to verify and measure what the translator emits.

Read the `docs/` specs before designing or changing any translation logic; the WASM → Udon mapping is non-trivial and the Udon VM has unusual constraints (see "Udon constraints that drive design" below).

## Toolchain & common commands

- Zig is pinned via `mise` (`mise.toml`); `build.zig.zon` requires `minimum_zig_version = "0.16.0"`.
- Build the CLI: `zig build` → `zig-out/bin/wasdon_zig`
- Run the CLI: `zig build run -- <args>` (`inspect`, `translate`, `check`, `run`)
- Run all tests: `zig build test` (add `-Drust` to include the Rust examples; needs `cargo` + the `wasm32v1-none` and `wasm32-wasip1` targets. `-Drhai` adds `examples/rhai-bench` and `-Dmruby` adds `examples/mruby-bench`, whole interpreters in Rust and C: run them after any change to `lower.zig` — they are the tests that find miscompilations. `-Dlinux=<path to vmlinux.wasm>` translates and boots a Linux kernel, see `examples/linux`)
- Build the example modules: `zig build examples`
- Size / executed-instruction table for every example: `zig build stats` (`-- --profile <example>` for an extern profile)
- Regenerate the examples' Unity assets: `zig build unity` — required after any change to the translator's output; `zig build test` fails while `unity/Wasdon/Examples/*.uasm.txt` is stale
- There is no separate lint step; rely on `zig fmt` / the compiler.

## Module layout

`build.zig` defines four library modules and the CLI:

- `src/wasm/` — WASM binary parser and `__udon_meta` decoding. Knows nothing about Udon.
- `src/udon/` — Udon Assembly. `asm.zig` builds and writes programs; `program.zig` reads the text back; `check.zig` validates it; `vm.zig` + `externs.zig` execute it; `nodes.zig` is the node list and signature parser. Knows nothing about WASM.
- `src/translator/` — the lowering. `translate.zig` is module level (what exists, events, init); `lower.zig` lowers function bodies; `callgraph.zig` finds recursion; `liveness.zig` finds the locals live at each call and the ones that are only conditions; `threads.zig` rewrites atomics for the one thread there is; `wasi.zig` links host interfaces into a module as WebAssembly — WASI preview 1, and the imports `__udon_meta.imports` binds; `inspect.zig` reports what a module needs.
- `src/root.zig` — the public library module (`@import("wasdon_zig")`).
- `src/main.zig` — the CLI; the only place that touches `std.process.Init`/stdio.

Unit tests live next to the code. Integration tests live in `test/`: `fixtures.zig` lists the examples (their WASM binaries are built by `build.zig` and imported by name — nothing generated is copied into `src/`), `examples_test.zig` verifies them, `stats.zig` measures them. `tools/unity_assets.zig` writes the examples' translations to `unity/Wasdon/Examples/`, the one place generated output is checked in.

Examples (`examples/README.md`) keep their logic in a `core.zig` with no Udon in it; the tests compile that natively and compare the Udon run with it bit for bit. `examples/bench` is the benchmark against UdonSharp, whose assembly is reproduced by `examples/bench/usharp/emit_usharp.py`.

## Testing policy

A translation is not "tested" until it has been **checked and executed**:

- Every program the tests translate must pass `udon.check.check` (Udon Assembly rules, node list, stack discipline, heap size) with zero findings.
- Behaviour is verified by running the result in `udon.vm.Vm` and comparing logs / heap variables / recorded calls — not by matching substrings of the assembly text.
- New WASM features get a test that executes them; new examples go in `test/fixtures.zig` with a scenario and expected output.
- The emulator faults on a .NET extern it does not implement; implement it (`src/udon/externs.zig`) rather than letting a default through.
- Performance work is recorded in `docs/benchmarks.md`: add a row with the numbers before and after (`zig build stats`).

## Udon constraints that drive design

These are the non-obvious target properties that shape every translation decision. `docs/udon_specs.md` is the language reference; `docs/udon_vm.md` records how the VM and assembler actually behave.

- **No local variables.** Every Udon variable is a field on the UdonBehaviour. WASM locals, the operand stack and translator state are heap slots, named per `docs/spec_variable_conversion.md`.
- **No call/return.** Only `JUMP`, `JUMP_INDIRECT`, and `JUMP_IF_FALSE`. Calls use return-address constants and per-function frames; recursion saves frames on an explicit stack (`docs/spec_call_return_conversion.md`).
- **`EXTERN` is the only computation, and it is the expensive instruction.** Arithmetic, comparisons, memory access — all externs with .NET signature strings. The lowering exists to minimize them: operands are read in place, results are written straight to their destination, comparisons stay `SystemBoolean` until needed as numbers.
- **Slots are strictly typed at run time.** A slot can only be read as the type last written to it; `COPY` retypes the destination. WASM integers therefore stay in `SystemInt32`/`SystemInt64` for life, unsigned operations are synthesized in the signed domain (`docs/spec_numeric_conversion.md`), and each slot is used at one type only.
- **Literals are limited.** Only `Int32`, `UInt32`, `Single` and `String` variables can have literal initial values. `Int64`/`Double`/inexact `Single` constants and data segments are decoded at startup from Base64 strings.
- **No raw memory.** Linear memory is one `SystemByteArray`; loads go through `BitConverter`, stores through `Buffer.BlockCopy` (`docs/spec_linear_memory.md`).
- **The heap has a fixed size chosen before assembly** — 512 slots in the stock asset. The translator reports the exact need and the Unity asset in `unity/Wasdon/` applies it (`docs/spec_heap_size.md`).
- **Missing externs fail silently.** A signature not in `docs/udon_nodes.txt` makes the behaviour halt at load with no useful message; the checker rejects such programs.
- **Translator-time metadata via `__udon_meta`.** Per `docs/spec_udonmeta_conversion.md`, the module may carry a UTF-8 JSON blob describing fields, event bindings and options. It is located through the exports `__udon_meta_ptr` / `__udon_meta_len`, which `src/wasm/const_eval.zig` (`evalExportedI32`) only accepts as (a) an exported global whose init is a single `i32.const`, or (b) an exported nullary function whose body is exactly one `i32.const` or one `global.get` of such a global — anything else fails with `NonConstMetaLocator`. The byte range must lie inside one data segment (`MetaSpansMultipleSegments` otherwise). It is never read at run time, and it is optional.

## Documentation policy

Whenever a new discovery, behavior, spec interpretation, or feature is introduced, you **must** add or update a corresponding document under `docs/`. Treat code changes and documentation updates as a single unit of work — neither is "done" without the other.

- **All documentation under `docs/` (and any new doc files added to the repo) must be written in English.** This applies to spec docs, design notes, and producer-side guides regardless of the language used in chat. Do not commit non-English prose into `docs/` or other repo-tracked documentation.
- New WASM instruction handling or Udon constraint behavior discovered → update the relevant existing spec (`docs/spec_*.md` / `docs/udon_specs.md`) or add a new one.
- New feature or translation pass added → record the design intent, inputs/outputs, and known limitations under `docs/`.
- Reproducible producer-side pitfall (Rust/Zig/WAT) discovered → append it to the producer-facing guide `docs/producer_guide.md`.
- Output size or speed changed → add the before/after numbers to `docs/benchmarks.md`.

When you add a new doc, also reflect it in the "Spec documents" list in this `CLAUDE.md` if it belongs there.

## `.gitignore` policy

The repo's `.gitignore` is for **project-level build artifacts and generated fixtures only** — things every checkout of this repo would produce regardless of who is working on it (e.g. `zig-out/`, `.zig-cache/`, `target/`).

Do **not** add user/environment-specific entries that are the contributor's own responsibility. Those belong in the user's global gitignore (`core.excludesFile`), not in this repo. Examples to keep out of `.gitignore`:

- OS metadata: `.DS_Store`, `Thumbs.db`, `Desktop.ini`
- Editor/IDE state: `.vscode/`, `.idea/`, `*.swp`, `.history/`
- Personal tooling state: `.claude/`, `.tmp/`, ad-hoc scratch files (`*.uasm` left in the repo root, one-off `*.wat`, etc.)
- Local secrets / credentials

Rule of thumb: if a file appears only because of *your* tool / editor / OS, it's user-responsibility. If it appears because *anyone* who builds this project produces it, it's project-responsibility and may be added.

## Spec documents (read these before designing translation passes)

- `docs/udon_specs.md` — Udon Assembly syntax, type-name rules, instruction set, EXTERN semantics. The target language reference.
- `docs/udon_vm.md` — how the Udon VM, heap and assembler actually behave (from the SDK), and the emulator and checker built on that.
- `docs/udon_nodes.txt` — every extern, type and event Udon exposes. The ground truth for what can be called.
- `docs/spec_call_return_conversion.md` — frames, the translation-time operand stack, calls/returns, control flow, recursion, events and initialization.
- `docs/spec_numeric_conversion.md` — numeric instructions → externs, unsigned operations in the signed domain, conversions, constants and the constant pool.
- `docs/spec_linear_memory.md` — linear memory as a `byte[]`: loads, stores, bulk operations, growth, data segments.
- `docs/spec_host_import_conversion.md` — imports as Udon externs: receivers, argument/result type mapping, strings, handles, Udon variables as imports.
- `docs/spec_udonmeta_conversion.md` — the `__udon_meta` JSON: fields (`global` / `import` / `symbol`), event bindings, options.
- `docs/spec_wasi_preview_1.md` — WASI preview 1: which functions exist, what each does on Udon, how they are linked in.
- `docs/spec_variable_conversion.md` — naming of every variable the translator emits.
- `docs/spec_heap_size.md` — why programs failed with a heap-size error, and how the size is now computed and applied.
- `docs/producer_guide.md` — producer-side guide: target features, host imports, sharing state, events, recursion, memory, and the build → translate → check → run pipeline.
- `docs/benchmarks.md` — the running record of output size and executed-instruction counts per example, including the comparison with UdonSharp.

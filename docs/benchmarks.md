# Benchmarks and optimization log

This file is the running record of how the translator's output changes over
time. Every optimization or redesign appends a row; the first row of each
table is the baseline it is measured against. Numbers are reproducible with
`zig build stats` (static columns) and the bundled Udon VM emulator (dynamic
columns) — see the "How the numbers are produced" section at the end.

Column meanings:

| Column | Meaning |
|---|---|
| `data` | Named variables declared in the `.data_start` section. |
| `externs` | `EXTERN` instructions in the code section (static count). |
| `uniq` | Distinct `EXTERN` signature strings. |
| `heap` | Udon heap slots the program needs: `data + uniq` (the assembler allocates one anonymous slot per distinct string literal). |
| `instr` | Instructions in the code section (static count). |
| `code bytes` | Bytecode size (4 or 8 bytes per instruction). |
| `uasm bytes` | Size of the rendered assembly text. |

## Static size

### Baseline — commit `7d44799` (per-instruction lowering, two-level `uint[]` memory)

| Example | wasm bytes | data | externs | uniq | heap | instr | code bytes | uasm bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `wasm-bench` (Zig) | 12493 | 2973 | 9313 | 69 | 3042 | 47944 | 371792 | 1983977 |
| `udon-orbit` (Zig) | 2589 | 870 | 554 | 42 | 912 | 2368 | 18760 | 134157 |
| `udon-orbit-rs` (Rust) | 1899 | 577 | 385 | 43 | 620 | 1692 | 13344 | 93469 |
| `wasm-bench-rs` (Rust) | 4408 | 1310 | 2234 | 53 | 1363 | 12248 | 94212 | 516959 |
| `wasm-bench-alloc-rs` (Rust) | 11041 | 2010 | 7665 | 62 | 2072 | 41441 | 319296 | 1648314 |

Observation: every example needs more than 512 heap slots, which is the heap
size the stock `UdonAssemblyProgramAsset` assembles with. This is the root of
the "heap size" failures seen in Unity (see `docs/spec_heap_size.md`).

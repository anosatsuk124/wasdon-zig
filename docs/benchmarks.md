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

### Redesign — same WASM binaries as the baseline

`byte[]` linear memory, lazy operand stack, Boolean comparisons, signed-domain
integers, dead function elimination, return modes, constant pool, Base64 data
segments (`docs/spec_linear_memory.md`, `docs/spec_call_return_conversion.md`,
`docs/spec_numeric_conversion.md`). The inputs are the very `.wasm` files the
baseline was measured on.

| Example | data | externs | uniq | heap | instr | code bytes | uasm bytes |
|---|---:|---:|---:|---:|---:|---:|---:|
| `wasm-bench` (Zig) | 674 | 1863 | 50 | 724 | 10341 | 80188 | 415 k |
| `udon-orbit-rs` (Rust) | 39 | 36 | 25 | 64 | 167 | 1320 | 9 k |
| `wasm-bench-rs` (Rust) | 357 | 419 | 35 | 392 | 2825 | 21380 | 110 k |
| `wasm-bench-alloc-rs` (Rust) | 631 | 1868 | 40 | 671 | 10231 | 79412 | 395 k |

| Example | heap: before → after | instructions: before → after | uasm text: before → after |
|---|---|---|---|
| `wasm-bench` | 3042 → 724 (−76 %) | 47944 → 10341 (−78 %) | 1984 k → 415 k |
| `udon-orbit-rs` | 620 → 64 (−90 %) | 1692 → 167 (−90 %) | 93 k → 9 k |
| `wasm-bench-rs` | 1363 → 392 (−71 %) | 12248 → 2825 (−77 %) | 517 k → 110 k |
| `wasm-bench-alloc-rs` | 2072 → 671 (−68 %) | 41441 → 10231 (−75 %) | 1648 k → 395 k |

(`udon-orbit` is not in this table: its metadata bound memory-backed
variables as WASM globals, which the old translator silently accepted and the
new one rejects. The example was corrected; see the next table.)

### Examples rebuilt with bulk memory

The Zig examples are now compiled with `bulk_memory_opt`, `sign_ext`,
`nontrapping_fptoint` and `mutable_globals` (`build.zig`), so `memcpy` /
`memset` are single externs. `zig build stats -Drust`:

| Example | wasm bytes | heap | instr | externs | code bytes | uasm bytes |
|---|---:|---:|---:|---:|---:|---:|
| `wasm-bench` | 12436 | 712 | 10338 | 1870 | 80228 | 415342 |
| `udon-orbit` | 2513 | 68 | 188 | 40 | 1484 | 11129 |
| `wasm-bench-rs` | 4408 | 392 | 2825 | 419 | 21380 | 110476 |
| `wasm-bench-alloc-rs` | 11041 | 671 | 10231 | 1868 | 79412 | 395482 |
| `udon-orbit-rs` | 1899 | 64 | 167 | 36 | 1320 | 9332 |

## Dynamic cost

Executed instruction counts in the bundled Udon VM emulator
(`docs/udon_vm.md`). `EXTERN` is the expensive instruction on the real VM —
each one is a delegate call plus one typed heap access per operand — so it is
tracked separately.

Scenarios:

- bench-style examples: `_onEnable, _start, _interact ×16, _update ×10`
- orbit examples: `_onEnable, _start, _update ×100, _interact ×2`

### Baseline — commit `7d44799`

| Example | instructions | externs | `_update` instr/frame | `_update` externs/frame |
|---|---:|---:|---:|---:|
| `wasm-bench` (Zig) | 386169 | 77567 | 105 | 21 |
| `udon-orbit` (Zig) | 47972 | 10174 | 421 | 88 |
| `udon-orbit-rs` (Rust) | 34885 | 6891 | 289 | 55 |
| `wasm-bench-rs` (Rust) | 278686 | 56129 | 151 | 31 |
| `wasm-bench-alloc-rs` (Rust) | 2315494 | 417177 | 105 | 21 |

Top externs executed by `wasm-bench` at the baseline, which is where the
redesign aims first — address arithmetic for the two-level memory, and the
`BitConverter` round trips between `Int32` and `UInt32`:

| executions | signature |
|---:|---|
| 8235 | `SystemInt32.__op_Addition__…` |
| 8184 | `SystemInt32.__op_RightShift__…` |
| 7455 | `SystemInt32.__op_LogicalAnd__…` |
| 5777 | `SystemInt32.__op_LessThan__…` |
| 4340 | `SystemObjectArray.__GetValue__…` |
| 4074 | `SystemInt32.__op_LessThanOrEqual__…` |
| 4060 | `SystemUInt32.__op_LogicalAnd__…` |
| 3804 | `SystemUInt32Array.__Get__…` |
| 3248 | `SystemInt32.__op_LeftShift__…` |
| 2666 | `SystemBitConverter.__GetBytes__SystemInt32__…` |
| 2666 | `SystemBitConverter.__ToUInt32__…` |

### Redesign — same WASM binaries as the baseline

Every example's log output is byte-identical to the baseline's.

| Example | instructions | externs | vs. baseline |
|---|---:|---:|---|
| `wasm-bench` (Zig) | 74677 | 14470 | 5.2× fewer instructions, 5.4× fewer externs |
| `udon-orbit-rs` (Rust) | 6928 | 1628 | 5.0× / 4.2× |
| `wasm-bench-rs` (Rust) | 52436 | 10977 | 5.3× / 5.1× |
| `wasm-bench-alloc-rs` (Rust) | 658023 | 128574 | 3.5× / 3.2× |

Per frame, `_update` of `udon-orbit-rs` went from 289 instructions / 55
externs to 68 / 16; the bench's trivial `_update` from 105 / 21 to 22 / 4
(the remaining cost is one memory load, add, store and the init guard).

The scenario no longer starts with `_onEnable`: initialization now runs
inside whichever event comes first (`docs/spec_call_return_conversion.md`
§7), so its cost is included in `_start` below.

### Examples rebuilt with bulk memory

| Example | instructions | externs |
|---|---:|---:|
| `wasm-bench` | 47663 | 8841 |
| `udon-orbit` | 8123 | 1926 |
| `wasm-bench-rs` | 52436 | 10977 |
| `wasm-bench-alloc-rs` | 658023 | 128574 |
| `udon-orbit-rs` | 6928 | 1628 |

`wasm-bench` drops a further 36 % (74677 → 47663) from the producer flag
alone: its formatting code copies short strings with `memcpy`.

| Example | event | instr / run | externs / run |
|---|---|---:|---:|
| `wasm-bench` | `_start` | 2871 | 577 |
| `wasm-bench` | `_interact` | 2785 | 514 |
| `wasm-bench` | `_update` | 22 | 4 |
| `udon-orbit` | `_update` | 80 | 19 |
| `wasm-bench-rs` | `_interact` | 2563 | 538 |
| `wasm-bench-alloc-rs` | `_interact` | 39963 | 7804 |
| `udon-orbit-rs` | `_update` | 68 | 16 |

## How the numbers are produced

```sh
zig build stats -Drust                       # the tables above (Markdown)
zig build stats -Drust -- --profile wasm-bench   # plus an extern profile
zig build stats -- --emit zig-out            # also write each .uasm
```

`test/fixtures.zig` defines each example's scenario; `test/stats.zig` runs
exactly what `test/examples_test.zig` verifies. Static columns come from the
translator (`Asm.Stats`) and are cross-checked against an independent parse
of the output; dynamic columns are `Vm.stats` from the emulator
(`docs/udon_vm.md` §5).

Baseline rows were measured by running the output of the translator at
commit `7d44799` through the same emulator.

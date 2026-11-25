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

## Application examples — optimization log

The examples added after the redesign (`pi`, `mandelbrot`, `image-codec`,
`ragdoll`, `blockfall`) are real workloads: long loops over linear memory,
floating point, byte parsing. They are what the optimization work is
measured on from here. Each step below is one change to the translator or to
an example; the tables give every example's numbers after that step, so any
row can be compared with any other.

Scenarios (`test/fixtures.zig`):

| Example | Scenario | What it covers |
|---|---|---|
| `pi` | `_start`, 30 frames | 100 digits: 25 spigot steps |
| `mandelbrot` | `_start`, 33 frames, `_interact`, 33 frames | two 64x64 views at 96 iterations, uploaded every frame |
| `image-codec` | `_start`, 50 frames, `_interact`, 50 frames | two 48x48 QOI pictures decoded, shown, re-encoded, compared |
| `ragdoll` | `_start`, 150 frames, `_interact`, 250 frames | 333 physics steps: walking, a hit, the fall, getting up |
| `blockfall` | `_start`, 610 frames, 28 button presses | a 13-trio game with clears and a chain, synced after every change |

### Step 0 — first working version

Every example translated and ran correctly on the first translator build it
was tried on; the only gap found was in metadata validation (a field of
type `VRCUdonUdonBehaviour` was rejected — `docs/udon_specs.md` §4.6).

Static size:

| Example | wasm bytes | heap | instr | externs | code bytes | uasm bytes |
|---|---:|---:|---:|---:|---:|---:|
| `wasm-bench` | 12436 | 712 | 10338 | 1870 | 80228 | 415374 |
| `udon-orbit` | 2513 | 68 | 188 | 40 | 1484 | 11160 |
| `pi` | 1468 | 103 | 638 | 125 | 5020 | 28129 |
| `mandelbrot` | 3491 | 212 | 1028 | 205 | 8064 | 47864 |
| `image-codec` | 17564 | 276 | 3147 | 617 | 24712 | 146204 |
| `ragdoll` | 6055 | 292 | 2783 | 562 | 21900 | 120585 |
| `blockfall` | 8059 | 376 | 4297 | 871 | 33804 | 174393 |
| `wasm-bench-rs` | 4408 | 392 | 2825 | 419 | 21380 | 110508 |
| `wasm-bench-alloc-rs` | 11041 | 671 | 10231 | 1868 | 79412 | 395514 |
| `udon-orbit-rs` | 1899 | 64 | 167 | 36 | 1320 | 9363 |

Every program fits the stock 512-slot heap except the two that carry a
formatting library (`wasm-bench`, `wasm-bench-alloc-rs`).

Executed by the scenario:

| Example | instructions | externs |
|---|---:|---:|
| `wasm-bench` | 47663 | 8841 |
| `udon-orbit` | 8123 | 1926 |
| `pi` | 317171 | 65624 |
| `mandelbrot` | 4256741 | 889572 |
| `image-codec` | 1781857 | 381012 |
| `ragdoll` | 10710170 | 2500108 |
| `blockfall` | 884123 | 186976 |
| `wasm-bench-rs` | 52436 | 10977 |
| `wasm-bench-alloc-rs` | 658023 | 128574 |
| `udon-orbit-rs` | 6928 | 1628 |

Per event (average over the scenario):

| Example | event | runs | instr / run | externs / run |
|---|---|---:|---:|---:|
| `pi` | `_start` | 1 | 11758 | 2489 |
| `pi` | `_update` | 30 | 10180 | 2104 |
| `mandelbrot` | `_start` | 1 | 11846 | 2455 |
| `mandelbrot` | `_update` | 66 | 64315 | 13440 |
| `image-codec` | `_update` | 100 | 17810 | 3808 |
| `ragdoll` | `_start` | 1 | 6356 | 1391 |
| `ragdoll` | `_update` | 400 | 26755 | 6245 |
| `ragdoll` | `_interact` | 1 | 1670 | 376 |
| `blockfall` | `_start` | 1 | 9722 | 2068 |
| `blockfall` | `_update` | 610 | 1011 | 213 |
| `blockfall` | `MoveLeft` | 7 | 6458 | 1363 |
| `blockfall` | `Rotate` | 4 | 9252 | 1966 |
| `blockfall` | `Drop` | 11 | 11846 | 2546 |

### Steps 1–3 — translator: branches, derived values, pending loads

Executed externs after each step (the scenario and the WASM are unchanged,
so every difference is the translator's):

| Example | step 0 | 1: two-jump branches | 2: derived-value cache | 3: pending loads |
|---|---:|---:|---:|---:|
| `wasm-bench` | 8841 | 8841 | 8750 | 8649 |
| `udon-orbit` | 1926 | 1926 | 1926 | 1926 |
| `pi` | 65624 | 65624 | 65624 | 65314 |
| `mandelbrot` | 889572 | 875148 | 875148 | 858749 |
| `image-codec` | 381012 | 381012 | 381012 | 380033 |
| `ragdoll` | 2500108 | 2459407 | 2411455 | 2355818 |
| `blockfall` | 186976 | 186366 | 186196 | 164988 |
| `wasm-bench-rs` | 10977 | 10977 | 10975 | 8810 |
| `wasm-bench-alloc-rs` | 128574 | 128574 | 127864 | 118484 |
| `udon-orbit-rs` | 1628 | 1628 | 1628 | 1628 |

Executed instructions:

| Example | step 0 | step 1 | step 2 | step 3 |
|---|---:|---:|---:|---:|
| `wasm-bench` | 47663 | 47663 | 47299 | 46922 |
| `pi` | 317171 | 317171 | 317171 | 316040 |
| `mandelbrot` | 4256741 | 4215879 | 4215879 | 4150286 |
| `image-codec` | 1781857 | 1781857 | 1781857 | 1778764 |
| `ragdoll` | 10710170 | 10602597 | 10410789 | 10243874 |
| `blockfall` | 884123 | 882598 | 881918 | 808892 |
| `wasm-bench-rs` | 52436 | 52436 | 52428 | 44461 |
| `wasm-bench-alloc-rs` | 658023 | 658023 | 655183 | 618262 |

Heap slots after step 3: `wasm-bench` 711, `pi` 102, `mandelbrot` 205,
`image-codec` 288, `ragdoll` 301, `blockfall` 383, `wasm-bench-rs` 389,
`wasm-bench-alloc-rs` 672 (the derived-value cache adds up to 8 shared
slots, byte constants one each).

1. **Two-jump branches.** `br_if` / `if` / `select` on a condition whose
   Boolean has the wrong sense and cannot be swapped for the opposite
   comparison (float `<`, `<=`, …: not invertible because of NaN) used to
   negate the Boolean with an extern. It is now `JUMP_IF_FALSE` over a
   `JUMP`: two cheap instructions on one path, one on the other, no extern.
2. **Derived-value cache.** `local + offset` (the address of a field) and
   `local ^ 0x80000000` (the operand of an unsigned comparison) are kept in
   eight shared slots while the local is unchanged, so a load and a store of
   the same field, or several unsigned comparisons of the same local,
   compute the value once (`docs/spec_linear_memory.md` §5).
3. **Pending loads.** A load is not emitted until its value is needed.
   A value loaded only to be stored becomes one `Buffer.BlockCopy` within
   memory (3–4 externs → 1); a byte tested for zero is one
   `BitConverter.ToBoolean`; a byte combined with another byte or a small
   constant uses the `SystemByte` operators, which return `Int32` and so
   absorb the conversion (`docs/spec_linear_memory.md` §3).

The profile at step 0 showed where the rest goes — address arithmetic
(`Int32` addition is 25–30 % of all externs in every example), the two
externs of each store, and the arithmetic itself:

| `ragdoll`, step 0 | executions |
|---|---:|
| `SystemInt32.__op_Addition__` | 640688 |
| `SystemBitConverter.__ToSingle__` (f32 load) | 409502 |
| `SystemSingle.__op_Multiplication__` | 235416 |
| `SystemSingle.__op_Subtraction__` | 210962 |
| `SystemBuffer.__BlockCopy__` (store, 2nd half) | 207977 |
| `SystemSingleArray.__Set__` (store, 1st half) | 205813 |
| `SystemSingle.__op_Addition__` | 172425 |
| `SystemInt32.__op_Multiplication__` | 59879 |
| `SystemByteArray.__Get__` + `SystemConvert.__ToInt32__` (byte load) | 2 × 56969 |
| `SystemBoolean.__op_UnaryNegation__` | 40701 |

### Steps 4–6 — masks and signs; the examples themselves

| Example | step 3 | 4: masks, non-negative locals | 5: wider fields, index loops | 6: table-driven drawing |
|---|---:|---:|---:|---:|
| `wasm-bench` | 8649 | 8649 | 8649 | 8649 |
| `pi` | 65314 | 65314 | 65314 | 65314 |
| `mandelbrot` | 858749 | 858461 | 858461 | 858461 |
| `image-codec` | 380033 | 377887 | 374798 | 374798 |
| `ragdoll` | 2355818 | 2355817 | 2355817 | 2355817 |
| `blockfall` | 164988 | 164938 | 149486 | 122632 |
| `wasm-bench-rs` | 8810 | 8778 | 8778 | 8778 |
| `wasm-bench-alloc-rs` | 118484 | 118466 | 118466 | 118466 |

(executed externs; `udon-orbit` and `udon-orbit-rs` are unchanged at 1926
and 1628.)

4. **Translator.** `(x & m) & c` narrows the constant of the first `&`
   instead of emitting a second — which is what `(x >>> k) & c` turns into,
   since the logical shift is an arithmetic shift and a mask. A local
   assigned a value known to be non-negative (a byte load, a masked value,
   a comparison) keeps that knowledge until the next label, so shifting or
   comparing it unsigned needs no mask or sign flip. Small effect on these
   programs: the patterns are in code that runs rarely.
5. **Examples.** `blockfall`'s state used `i8`/`u8` fields and iterated
   arrays by value (`for (g.dx, g.dy) |dx, dy|`), which in Zig copies the
   arrays to the stack first. With 32-bit fields and index loops a button
   press costs 1033 externs instead of 1363. The QOI decoder now keeps the
   input slice in a local, which saves reloading the pointer after every
   store. Both are recorded in `docs/producer_guide.md` §9.
6. **Examples.** `blockfall` painted each cell through two tests and a
   palette lookup, and repainted the static divider and panel every time.
   A lookup table indexed by the cell value (flash bit included) and a
   frame drawn once bring a redraw from 1033 externs to 727.

`blockfall` over the whole log: 186976 → 122632 executed externs (−34 %);
per button press 1363 → 727; per frame while a trio falls 213 → 151.

### Steps 7–9 — recursion; against UdonSharp

`examples/bench` holds one benchmark in four programs: UdonSharp, Zig,
Rust, and Rust with `std` built for WASI (`examples/bench/README.md`). The
UdonSharp side is the assembly its compiler emits, reproduced from the
compiler's emit routines, and run in the same emulator.

The first measurement had the translated recursion *slower* than
UdonSharp's: every local, every block-result slot and the return address
were saved around a recursive call, two externs each way per slot.

Executed externs per workload:

| | UdonSharp | Zig: before | 7: live slots, columns, Boolean locals | 8: return address on the VM stack | Rust (after 8) |
|---|---:|---:|---:|---:|---:|
| `Fib` | 251748 | 317413 | 164185 | 142294 | 164185 |
| `Mandel` | 20657 | 16920 | 16920 | 16920 | 16920 |
| `Str` | 194 | 69 | 69 | 69 | 69 |
| total | 272599 | 334402 | 181174 | 159283 | 181174 |
| instructions | 1438788 | 1603224 | 1001255 | 913692 | 951694 |

7. **Frames.** A liveness pass finds, for every call, the locals read
   again before they are overwritten; only those are saved. The recursion
   stack is stored by column (`__frame{k}[depth]`), so a slot costs one
   extern to save and one to restore, plus one counter update each way.
   A local that only ever holds a condition is declared `SystemBoolean`,
   which removes a conversion at its store and a comparison at its test —
   here the loop condition LLVM computes before the last statements of the
   loop body. `Fib`: 27 externs per iteration → 14.
8. **Return addresses.** A recursive function's callers `PUSH` the return
   address and leave it on the VM stack; the function pops it to return, as
   UdonSharp's methods do. The address no longer needs a slot, so it no
   longer needs saving: 14 → 12.
9. **WASI.** `wasi_snapshot_preview1` imports are linked in as functions
   written in WebAssembly (`docs/spec_wasi_preview_1.md`). The Rust `std`
   program `examples/bench/wasi-rs` — `println!`, `String`, `Instant` — runs
   185933 externs for all three workloads and their output, and Zig's
   `examples/wasi-hello` 15437.

Effect of steps 7–8 on the other examples (executed externs): `wasm-bench`
8649 → 8122, `wasm-bench-rs` 8778 → 8251, the rest unchanged (no
recursion, no condition locals in hot code).

All examples after step 9 (`zig build stats -Drust`):

| Example | heap | instr | externs | executed instr | executed externs |
|---|---:|---:|---:|---:|---:|
| `wasm-bench` | 711 | 10171 | 1829 | 44813 | 8122 |
| `udon-orbit` | 68 | 188 | 40 | 8123 | 1926 |
| `pi` | 102 | 621 | 120 | 316040 | 65314 |
| `mandelbrot` | 205 | 974 | 190 | 4149134 | 858461 |
| `image-codec` | 288 | 3097 | 603 | 1757824 | 374798 |
| `ragdoll` | 301 | 2733 | 546 | 10243870 | 2355817 |
| `blockfall` | 358 | 3154 | 574 | 595429 | 122632 |
| `wasi-hello` | 1923 | 34405 | 6286 | 79584 | 15437 |
| `bench-usharp` (UdonSharp) | 86 | 332 | 57 | 1438788 | 272599 |
| `bench-zig` | 113 | 1751 | 338 | 913692 | 159283 |
| `bench-rs` | 113 | 1755 | 341 | 951694 | 181174 |
| `bench-wasi-rs` | 2480 | 59574 | 11404 | 976631 | 185933 |
| `wasm-bench-rs` | 388 | 2741 | 398 | 42224 | 8251 |
| `wasm-bench-alloc-rs` | 670 | 9458 | 1659 | 618190 | 118466 |
| `udon-orbit-rs` | 64 | 167 | 36 | 6928 | 1628 |

Against the very first baseline (commit `7d44799`), on the examples that
existed then: `wasm-bench` 77567 → 8122 executed externs (9.6×),
`wasm-bench-rs` 56129 → 8251 (6.8×), `wasm-bench-alloc-rs` 417177 → 118466
(3.5×), `udon-orbit-rs` 6891 → 1628 (4.2×); heap 3042 → 711, 1363 → 388,
2072 → 670, 620 → 64.

### Step 10 — an interpreter; `br_table` as an indexed jump

`examples/rhai-bench` is the Rhai scripting engine (Rust `std`, WASI)
interpreting the benchmark's three workloads from source: 1 105 170 bytes
of WebAssembly, 3 360 functions. It is built and measured with `-Drhai`.

Getting it to run at all took three fixes to the lowering (a local read
before a re-entrant call and consumed after it was not saved; code emitted
on the taken path of a value-carrying `br_if` changed the operand stack for
both paths; `p = p.next` left a stale `p + offset` in the derived-value
cache). None of them changes the numbers of the other examples.

Its extern profile then showed 12.6 million `Int32 ==`: `br_table` was a
chain of equality tests, `i + 1` externs for case `i`, and an interpreter
is made of `match`es. With five or more cases it is now a bounds test and
a `uint[]` of code addresses indexed by the operand
(`docs/spec_call_return_conversion.md` §5) — two or three externs for any
case.

| Example | executed externs before | after | static externs before | after | heap before | after |
|---|---:|---:|---:|---:|---:|---:|
| `rhai-bench-rs` | 115361081 | 109765017 | 212914 | 211912 | 56183 | 56412 |
| `wasm-bench` | 8122 | 8037 | 1829 | 1820 | 711 | 716 |
| `wasm-bench-rs` | 8251 | 8211 | 398 | 398 | 388 | 395 |
| `wasm-bench-alloc-rs` | 118466 | 118426 | 1659 | 1659 | 670 | 677 |
| `wasi-hello` | 15437 | 15438 | 6286 | 6240 | 1923 | 1968 |
| `bench-wasi-rs` | 185933 | 185936 | 11404 | 11374 | 2480 | 2485 |

The two WASI programs gain one to three externs: their tables are set up
at startup (two externs each) and the formatting code that owns them runs
only a few times. The other examples have no `br_table` with five cases
and are unchanged. Each table costs one heap slot and, at most, two
constants.

What the interpreter spends its 110 million externs on, after the change
(`zig build stats -Drhai -- --profile rhai-bench-rs`): 29.0 M `Int32 +`
(addresses and the shadow stack pointer), 10.5 M `ToInt32` loads, 9.1 M
`BlockCopy` (stores and copies), 12.7 M frame saves and restores, 5.6 M
`Int32Array.Set` (the first half of a non-constant store).

For scale: the same workloads compiled ahead of time (`bench-wasi-rs`)
run 185 936 externs — interpretation costs about 590×. And translated with
every switchable optimization off (`translate --without liveness,
stack_return,bool_locals,pending_loads,memory_copies,byte_operators,
derived,masks,jump_tables`) the interpreter runs 146 642 543 externs and
787 262 061 instructions: on this program the optimizations of steps 1–10
that can be switched off are worth a quarter of the externs.

**mruby** (`examples/mruby-bench`, `-Dmruby`) is the same experiment in C:
mruby 3.3.0 built with `zig cc` for `wasm32-wasi`, running the workloads
from Ruby bytecode. It translated, passed the checker and printed the
right results at the first attempt — after the three fixes above. Its
bytecode dispatch is one `switch` with a case per opcode, so it shows what
the indexed jump is worth:

| `mruby-bench` | executed instr | executed externs |
|---|---:|---:|
| every switchable optimization off | 184702800 | 38110485 |
| all on, `br_table` as a chain of comparisons | 164739717 | 33069048 |
| all on (step 10) | 107882591 | 23789796 |

All examples after step 10 (`zig build stats -Drust -Drhai -Dmruby`):

| Example | heap | instr | externs | executed instr | executed externs |
|---|---:|---:|---:|---:|---:|
| `wasm-bench` | 716 | 10093 | 1820 | 44235 | 8037 |
| `udon-orbit` | 68 | 188 | 40 | 8123 | 1926 |
| `pi` | 102 | 621 | 120 | 316040 | 65314 |
| `mandelbrot` | 205 | 974 | 190 | 4149134 | 858461 |
| `image-codec` | 287 | 3097 | 603 | 1757824 | 374798 |
| `ragdoll` | 301 | 2733 | 546 | 10243870 | 2355817 |
| `blockfall` | 358 | 3154 | 574 | 595429 | 122632 |
| `wasi-hello` | 1968 | 33918 | 6240 | 79534 | 15438 |
| `bench-usharp` (UdonSharp) | 86 | 332 | 57 | 1438788 | 272599 |
| `bench-zig` | 113 | 1751 | 338 | 913692 | 159283 |
| `bench-rs` | 113 | 1755 | 341 | 951694 | 181174 |
| `bench-wasi-rs` | 2485 | 59337 | 11374 | 976643 | 185936 |
| `wasm-bench-rs` | 395 | 2726 | 398 | 41934 | 8211 |
| `wasm-bench-alloc-rs` | 677 | 9443 | 1659 | 617900 | 118426 |
| `udon-orbit-rs` | 64 | 167 | 36 | 6928 | 1628 |
| `rhai-bench-rs` | 56412 | 1180797 | 211912 | 624933773 | 109765017 |
| `mruby-bench` | 16707 | 498255 | 99721 | 107882591 | 23789796 |

### Step 11 — the Linux kernel

`examples/linux`: the `vmlinux.wasm` of joelseverin/linux-wasm (Linux
6.4.16), 29 966 656 bytes, 9 970 functions, 6 523 atomic instructions, 96
host imports. With atomics rewritten for one thread, the imports bound in
a sidecar and the command line given through a string field, it
translates, passes the checker, and boots in the emulator through
`start_kernel` to the first context switch, printing 33 lines of kernel
log (`zig build stats -Dlinux=<path>`):

| Example | heap | instr | externs | executed instr | executed externs |
|---|---:|---:|---:|---:|---:|
| `linux` | 127370 | 3089877 | 587249 | 249565381 | 51691377 |

The translation takes under a second and the run three, in a release
build. Where the externs go: 17.3 M `Int32 +`, 13.9 M `BlockCopy` and
12.6 M `Int32Array.Set` — the kernel clearing and initializing its page
structures a word at a time — then 2.6 M `Int32 ==` and 1.0 M `ToInt32`
loads.

The existing examples are unchanged by this step: their translations are
byte for byte what they were (the Unity assets did not need regenerating).

### An experiment not adopted: every example at `ReleaseFast`

Building the Zig examples for speed instead of size, measured after step 2:
`wasm-bench` 8841 → 5809 executed externs, `blockfall` 186976 → 129305,
the numeric ones 2–5 % fewer — at 1.5–3.3× the code. The benchmark is
built that way; the others stay small, and `docs/producer_guide.md` §9a
says when the trade is worth making.

## How the numbers are produced

```sh
zig build stats -Drust                       # the tables above (Markdown)
zig build stats -Drust -Drhai -Dmruby        # … with the Rhai and mruby interpreters
zig build stats -Dlinux=vmlinux.wasm         # … with a Linux kernel (examples/linux)
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

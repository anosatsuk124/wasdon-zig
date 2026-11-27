# Benchmark: UdonSharp, Zig, Rust

Five workloads — the three of the mruby and Rhai benchmarks on the
`wasi-preview-1` branch, minus the interpreter, and the two classic
recursion tests — in four programs:

| Directory | Program | Path to Udon Assembly |
|---|---|---|
| [`usharp/`](usharp/) | `UdonBench.cs`, an UdonSharp behaviour | UdonSharp's compiler |
| [`zig/`](zig/) | Zig, freestanding, calls Udon directly | wasm → wasdon-zig |
| [`rs/`](rs/) | Rust, `no_std`, calls Udon directly | wasm → wasdon-zig |
| [`wasi-rs/`](wasi-rs/) | Rust with `std`: `println!`, `String`, `Instant` | wasm32-wasip1 → wasdon-zig |

| Workload | What it is |
|---|---|
| `Fib` | `fib(20)` by naive recursion: 21 891 calls |
| `Mandel` | escape iterations summed over a 16 × 8 grid, in integer fixed point |
| `Str` | `"abc"` appended to a string 64 times |
| `Tak` | the Takeuchi function, `tarai(8, 4, 0)`: 12 605 calls, three of every four nested in another call's arguments |
| `Ack` | the Ackermann function, `ack(3, 4)`: 10 307 calls, 123 deep even after tail calls are removed |

The first three programs expose each workload as an Udon event and leave
its result in an Udon variable (`fibResult`, `mandelResult`, `strResult`,
`takResult`, `ackResult`), so that formatting and logging are not part of
what is measured; the inputs are Udon variables too, so nothing is
computed at compile time. The WASI program is an ordinary `main` that
prints the first three and the elapsed time.

## Results

Executed in the repository's Udon VM emulator (`docs/udon_vm.md`);
`zig build stats -Drust` prints the table. An `EXTERN` is the expensive
instruction on the Udon VM, so that is the number to compare. The Zig and
Rust programs execute the same number of externs in every workload.

| Workload | UdonSharp | Zig and Rust | UdonSharp ÷ translated |
|---|---:|---:|---:|
| `Fib` | 251 748 | 76 626 | 3.29 |
| `Mandel` | 20 657 | 16 920 | 1.22 |
| `Str` | 194 | 69 | 2.81 |
| `Tak` | 248 936 | 22 058 | 11.29 |
| `Ack` | 164 664 | 38 000 | 4.33 |
| all five | 686 199 | 153 673 | 4.47 |

| | |
|---|---:|
| mean of the five ratios | 4.59 |
| geometric mean of the five ratios | 3.53 |
| instructions of any kind: UdonSharp | 3 656 398 |
| instructions of any kind: Zig, Rust | 1 204 697, 1 097 602 (3.0×, 3.3× fewer) |

Two of the five are below 3×, and they will stay there: `Mandel` is
arithmetic, where one extern per operation is the floor for everyone, and
`Str` is 64 calls of `String.Concat` either way.

The price of the recursion results is code: the translated program has
12 084 instructions and 1 297 heap slots where it had 2 064 and 146 before
the first levels of each recursive function got copies of their own
(below). UdonSharp's has 1 091 and 171.

The WASI program — `Fib`, `Mandel` and `Str` with `println!` included —
runs 98 376 externs (560 727 instructions), against UdonSharp's 272 599
for those three bare workloads.

Where the differences come from:

- **Recursion (`Fib`, `Tak`, `Ack`).** UdonSharp's `[RecursiveMethod]`
  checks the size of its stack before every call (3 externs) and pushes
  and pops every value it must keep — the parameters, and the results of
  earlier arguments still waiting for the call they belong to — with two
  externs each. Counting everything, a call of `FibRec` that recurses
  costs 23 externs and one of `TakRec` 79 (four calls, three of them
  holding other calls' results); `AckRec` spends 30 on its longest path.

  The translated versions start from better code — LLVM turns every tail
  call into a loop, which removes one of `fib`'s two calls, one of
  `tarai`'s four and both of `ack`'s outer ones — and then do not save
  anything at all for the first 64 levels: the translator gives each of
  those levels its own copy of the function, with its own slots
  (`docs/spec_call_return_conversion.md` §6). A call is then a few
  `COPY`s and two jumps. What is left is the arithmetic — the comparisons
  and subtractions the functions consist of: 7 externs per loop iteration
  of `fib`, and 7 per call of `tarai` that recurses. `ack(3, 4)`
  goes 123 deep, so its lower levels run in the original function and
  save frames (one extern per live slot each way, plus the depth counter);
  that is why it gains less.
- **`Mandel`.** The inner loop is 14 externs per iteration in all three:
  one per arithmetic operation is the floor on this VM, and UdonSharp
  already emits exactly that. The translated versions win outside it,
  where LLVM folds constants (`px * 3072 / 16` is `px * 192`), hoists and
  unrolls.
- **`Str`.** All three build a .NET string with `String.Concat`, one
  extern per append. UdonSharp also runs the loop — a comparison and an
  increment per iteration — which LLVM unrolls away.

In short: straight-line arithmetic is a tie, and everything a compiler can
remove — call overhead, loop control, constant subexpressions — is where
an optimizing compiler in front of the translator wins.

## The UdonSharp side

UdonSharp runs inside the Unity editor, which the test environment does not
have. `usharp/UdonBench.uasm` is therefore **reproduced**: written by
`usharp/emit_usharp.py`, whose helpers follow the emit routines of the
UdonSharp 1.x compiler
(`Packages/com.vrchat.UdonSharp/Editor/Compiler/`) one for one:

| UdonSharp | What it emits |
|---|---|
| `BoundInvocationExpression` on an operator | `PUSH a; PUSH b; PUSH result; EXTERN` — one per operator, the assignment target as result slot |
| `BoundWhileStatement`, `BoundIfStatement` | condition, `JUMP_IF_FALSE`, body, `JUMP` |
| `UdonSharpBehaviourMethodSymbol.Emit` | `PUSH` of the exit address `0xFFFFFFFF` at every method entry |
| `RetInstruction` | `PUSH returnJump; COPY; JUMP_INDIRECT returnJump` |
| `BoundUserMethodInvocation` | `PUSH` of a return-address constant, argument `COPY`s, `JUMP` |
| … inside a `[RecursiveMethod]` | `CheckStackSize` (array length, add, compare, resize branch), `PushRecursiveValues` (`Set` + increment per value), `PopRecursiveValues` (decrement + `Get` per value) for the parameters and every value held across the call. For a call nested in another call's arguments (`TakRec(TakRec(…), TakRec(…), …)`) the held values are the results of the arguments already evaluated (`EmitContext.CollectRecursiveValues`: values with open references) |

Where the compiler's behaviour was open to more than one reading, the
cheaper one for UdonSharp was taken: only values with open references are
saved, and self-assignments of parameters cost nothing. The numbers above
depend on this reproduction being right; it has not been compared with
the output of a real UdonSharp build.

No optimization is applied because UdonSharp applies none at this level;
the count per source statement can be read off the file, which is
annotated with the statement each group of instructions comes from.

To replace it with the real thing: put `UdonBench.cs` in a Unity project
with UdonSharp, create its UdonSharp program asset, copy the text under
*Compiled C# Udon Assembly* in the asset's inspector over
`UdonBench.uasm`, and run `zig build test`. (Constants appear there with
`null` initial values, since UdonSharp writes them to the heap directly;
give the integer and string constants their values as in the file here.)
The test checks the five results, so a faithful file passes it.

## Running

```sh
zig build stats -Drust                 # all four, with per-event counts
zig build stats -- --profile bench-zig # which externs
zig build test -Drust                  # results verified for every program
```

In Unity, `unity/Wasdon/Examples/bench-zig.asset` is the Zig version; send
its behaviour the custom events `Fib`, `Mandel`, `Str`, `Tak` and `Ack`.

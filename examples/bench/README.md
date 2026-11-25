# Benchmark: UdonSharp, Zig, Rust

The same three workloads — those of the mruby and Rhai benchmarks on the
`wasi-preview-1` branch, minus the interpreter — in four programs:

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

The first three programs expose each workload as an Udon event and leave
its result in an Udon variable (`fibResult`, `mandelResult`, `strResult`),
so that formatting and logging are not part of what is measured. The WASI
program is an ordinary `main` that prints all three and the elapsed time.

## Results

Executed in the repository's Udon VM emulator (`docs/udon_vm.md`);
`zig build stats -Drust` prints the table. An `EXTERN` is the expensive
instruction on the Udon VM, so that is the number to compare.

| Workload | UdonSharp | Zig | Rust | |
|---|---:|---:|---:|---|
| `Fib` | 251 748 | 142 294 | 164 185 | 1.8× / 1.5× fewer |
| `Mandel` | 20 657 | 16 920 | 16 920 | 1.2× fewer |
| `Str` | 194 | 69 | 69 | 2.8× fewer |
| all three | 272 599 | 159 283 | 181 174 | 1.7× / 1.5× fewer |
| instructions of any kind | 1 438 788 | 913 692 | 951 694 | |

The WASI program — the whole thing, `println!` included — runs 185 936
externs (976 643 instructions): still under UdonSharp's 272 599 for the
bare workloads.

Where the differences come from:

- **`Fib`.** UdonSharp's `[RecursiveMethod]` checks the size of its stack
  before every call (3 externs) and pushes and pops every value it must
  keep with two externs each: 22 externs per call of `FibRec`, two
  recursive calls each. LLVM turns the second recursive call into a loop,
  so there is one call per iteration, and the translator saves only the
  values live after it (two) in per-slot columns: 12 externs per iteration
  in Zig (`docs/spec_call_return_conversion.md` §6).
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
| … inside a `[RecursiveMethod]` | `CheckStackSize` (array length, add, compare, resize branch), `PushRecursiveValues` (`Set` + increment per value), `PopRecursiveValues` (decrement + `Get` per value) for the parameters and every value held across the call |

No optimization is applied because UdonSharp applies none at this level;
the count per source statement can be read off the file, which is
annotated with the statement each group of instructions comes from.

To replace it with the real thing: put `UdonBench.cs` in a Unity project
with UdonSharp, create its UdonSharp program asset, copy the text under
*Compiled C# Udon Assembly* in the asset's inspector over
`UdonBench.uasm`, and run `zig build test`. (Constants appear there with
`null` initial values, since UdonSharp writes them to the heap directly;
give the integer and string constants their values as in the file here.)
The test checks the three results, so a faithful file passes it.

## Running

```sh
zig build stats -Drust                 # all four, with per-event counts
zig build stats -- --profile bench-zig # which externs
zig build test -Drust                  # results verified for every program
```

In Unity, `unity/Wasdon/Examples/bench-zig.asset` is the Zig version; send
its behaviour the custom events `Fib`, `Mandel` and `Str`.

# Udon VM reference behaviour and the bundled emulator

`docs/udon_specs.md` describes the assembly language. This document records
how the VM that executes it actually behaves, because several translation
decisions depend on details the language description does not cover, and
describes the emulator and checker in `src/udon/` that are built on those
details.

## 1. Where the facts come from

Everything in §2–§4 was read out of the IL of the VRChat Worlds SDK
(`com.vrchat.worlds` 3.10.6: `VRC.Udon.VM.dll`, `VRC.Udon.Common.dll`,
`VRC.Udon.UAssembly.dll`, `VRC.Udon.EditorBindings.dll`) and from the
UdonSharp sources shipped with it. String literals and constants quoted here
are exact; the control flow is a reconstruction. Nothing was executed in
Unity.

## 2. Interpreter

The bytecode is a `uint[]`; the program counter is a byte offset. The stack
is a stack of `uint` heap indices (initial capacity 1024).

| Opcode | # | PC advance | Behaviour |
|---|---|---|---|
| `NOP` | 0 | 4 | — |
| `PUSH` | 1 | 8 | Push the parameter. |
| `POP` | 2 | 4 | Pop; an empty stack halts the behaviour. |
| `JUMP_IF_FALSE` | 4 | 8 | Pop an index, read it as `bool`; jump if false. |
| `JUMP` | 5 | — | Jump. |
| `EXTERN` | 6 | 8 | Pop the extern's parameter count, call the delegate. |
| `ANNOTATION` | 7 | **8** | Nothing. |
| `JUMP_INDIRECT` | 8 | — | Read the parameter's heap slot as `uint`, jump. |
| `COPY` | 9 | 4 | Pop destination, pop source, copy the heap value. |

- The loop runs while `pc < 0xFFFFFFFF` and `pc + 3` is inside the bytecode.
  `JUMP, 0xFFFFFFFC` therefore ends execution normally; so does any other
  jump past the end.
- Jump targets must be multiples of 4, otherwise
  `Unaligned jump address '0x…'. Addresses must be aligned to 4-byte boundaries.`
- `EXTERN` pops **exactly** the parameter count the wrapper reports for the
  signature. Values left under them stay on the stack.
- On first execution `EXTERN` replaces the string in its operand slot with a
  cached delegate (`CachedUdonExternDelegate`); all call sites of one
  signature share that slot.
- Any exception sets `_halted`, and `UdonBehaviour.RunProgram` logs
  `An exception occurred during Udon execution, this UdonBehaviour will be halted.`
  and disables the behaviour. `_halted` is never cleared.
- A program that references a signature the wrapper does not know fails when
  the behaviour loads its program, before any event runs.

### Time limit

`UdonVM.MAX_VM_TIME_MS = 10000`. The check runs on `JUMP`, `JUMP_IF_FALSE`,
`JUMP_INDIRECT` and `EXTERN` only, against a clock with ~100 ms resolution,
per `Interpret()` call — that is, per event. Exceeding it throws
`Program execution time exceeded max VM time of 10.0 seconds.` and halts the
behaviour. Long computations must therefore be split across events (see the
`pi` and `mandelbrot` examples).

## 3. Heap

The heap is an `IStrongBox[]`. Each slot holds a `StrongBox<T>`; the `T` is
the slot's current type.

- **Capacity.** `UdonHeap()` allocates `DEFAULT_CAPACITY = 512` slots.
  `UdonHeap(uint capacity)` clamps to `MAXIMUM_CAPACITY = 1048576` without
  complaint. Touching an address outside the array throws
  `IndexOutOfRangeException`:
  `Address: '512' is larger than the UdonVM's heap size of '512'.`
  The consequences for assembling programs are in `docs/spec_heap_size.md`.
- **Typed read** (`GetHeapVariable<T>`, used for every extern input, for
  `JUMP_IF_FALSE` as `bool` and for `JUMP_INDIRECT` as `uint`): returns the
  value if the box is exactly `StrongBox<T>`; otherwise returns `default(T)`
  when the boxed value is null, the value when it `is T`, and throws
  `Cannot retrieve heap variable of type 'X' as type 'Y'` when it is not.
  An `Int32` is never readable as `UInt32`, `Int64`, or `Boolean`.
- **Typed write** (`SetHeapVariable<T>`, used for every extern output):
  reuses the box when it is already `StrongBox<T>`, otherwise replaces it
  with a new one. The slot's type becomes `T`.
- **`COPY`** never converts and never fails on a type difference: the
  destination takes the source's type. When the types already match the
  destination box is reused; when they differ a new box is allocated. For
  primitives the type test is a linear chain (float, double, int, uint,
  short, ushort, byte, sbyte, char, long, ulong, bool, string); arrays,
  `object` and Unity structs fall through all thirteen tests and then go
  through `IStrongBox.Value`.

Two consequences shape the translator:

1. A slot must only ever be read as the type it was last written with, so
   WASM `i32` values are kept in `SystemInt32` slots for their whole life and
   unsigned operations are synthesized in the signed domain instead of being
   routed through `SystemUInt32`.
2. Writing a different type into a slot allocates. Every slot the translator
   declares is therefore used at one type only (the checker enforces this for
   primitive types), which keeps steady-state execution allocation-free.

## 4. Assembler

- Data declarations are assigned heap addresses sequentially from 0.
- A string literal used as an instruction parameter becomes an anonymous
  heap variable. **Identical literals share one slot**
  (`CreateAnonymousStringVariable` keeps a `Dictionary<string, uint>`), so a
  program's heap need is *declared variables + distinct string literals*.
  UdonSharp computes its heap size with exactly that formula.
- The assembler performs no heap-size check; overflow surfaces as the
  `IndexOutOfRangeException` above, shown in the asset's "Assembly Error" box.

## 5. The emulator (`src/udon/vm.zig`)

`Vm` executes a `Program` parsed from assembly text by `src/udon/program.zig`
(an independent reader — it shares no code with the writer the translator
uses) with the semantics above:

- typed heap values and strict typed reads, including the "null reads as
  default" rule and `COPY` retyping;
- `EXTERN` resolved once per distinct signature;
- re-entrant `run`, so `SendCustomEvent` nests as it does in Udon;
- a step limit standing in for the 10 s watchdog.

It is stricter than the real VM in one respect: by default it faults when
heap indices are left on the stack after a consuming instruction
(`Options.strict_stack`). The real VM tolerates that; translated code never
does it, so it is treated as a translator bug.

Externs (`src/udon/externs.zig`):

- `System.*` primitives, `System.Convert` (checked, round-half-to-even),
  `System.BitConverter`, `System.Buffer`, `System.Array`, `System.Math`,
  `UnityEngine.Mathf`, strings, `System.Text.Encoding`, `Debug.Log` — with
  .NET semantics, because translated programs depend on them bit for bit.
- A few Unity members with real behaviour (`Vector3` math, `Time`,
  `Transform.GetChild`, `Texture2D.LoadRawTextureData`, `VRCInstantiate`,
  `SendCustomEvent`, …).
- Everything else on a Unity/VRChat type goes to a **generic object model**:
  `get_X`/`set_X` read and write a per-object property bag, arrays of any
  element type work, and other calls are recorded in `Vm.calls` and return
  the result type's default (or a fresh placeholder object). Tests drive a
  mock scene and assert on what the program did to it.

Statistics: `Vm.stats` counts executed instructions and `EXTERN`s (total and
per opcode); `Vm.profile()` lists signatures by execution count. These are
the "dynamic" numbers in `docs/benchmarks.md`.

CLI:

```sh
wasdon-zig run program.uasm --events "_start,_interact*3,_update*60" --profile
```

`_update` advances the emulated clock by one frame before each run.

## 6. The checker (`src/udon/check.zig`)

`check` validates a parsed program against `docs/udon_specs.md` and the node
list (`docs/udon_nodes.txt`). The translator's tests run it on every program
they produce.

| Spec | Check |
|---|---|
| §2 | Sections present, in order, exactly once. |
| §4.4 | Variable and label names; duplicates. |
| §4.6–4.7 | Literal form allowed for the declared type; `this` only on `GameObject` / `Transform` / UdonBehaviour slots; `Int32.MinValue` spelled in hex; `UInt32` above `Int32.MaxValue` carries the `u` suffix; declared types exist in the node list. |
| §4.8 | `.export` / `.sync` name declared variables; sync mode is valid. |
| §5.2 | No two labels at one address; no label after the last instruction. |
| §5.3, §8 | Exported labels are defined; a label starting with `_` is a standard event from the node list. |
| §6 | Parameters present and of the right kind; `JUMP` / `JUMP_IF_FALSE` targets are instruction boundaries or `0xFFFFFFFC`; values that flow through `COPY` into a `JUMP_INDIRECT` operand are instruction addresses; the program cannot run off its end. |
| §6.2 | Stack discipline: `COPY` finds exactly two operands, `JUMP_IF_FALSE` exactly one `SystemBoolean`, `EXTERN` exactly its operands; nothing is left on the stack at a jump or a jump target. |
| §7 | Every `EXTERN` names a node in the list; operand count matches the signature (plus one for an instance receiver); primitive argument and result types match the declared types of the operands. |
| `docs/udon_vm.md` §3 | `COPY` and extern results never retype a primitive slot; heap size within `MAXIMUM_CAPACITY`. |

It also reports the heap size the program needs.

```sh
wasdon-zig check program.uasm
```

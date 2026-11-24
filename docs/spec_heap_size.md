# Heap Size

## 1. The error

Assembling a translated program in a stock **Udon Assembly Program Asset**
fails with

```
IndexOutOfRangeException: Address: '512' is larger than the UdonVM's heap size of '512'.
```

in the asset's "Assembly Error" box, and the UdonBehaviour has no program.

## 2. Cause

The Udon heap is a fixed-size array created before assembly
(`docs/udon_vm.md` §3–§4):

- `UdonAssemblyProgramAsset` assembles through `UdonEditorManager`, whose
  heap factory calls `new UdonHeap()` — **512 slots**, always.
- The assembler assigns one slot per declared variable and one per
  *distinct* string literal used as an instruction operand (every `EXTERN`
  signature), sequentially from 0, and never checks the total. Slot 512
  throws.

So a program fits the stock asset only if

```
heap slots = declared variables + distinct extern signatures ≤ 512
```

UdonSharp and Udon Graph do not hit this because they assemble with their
own heap factory sized from the program; hand-written or generated assembly
gets the default.

Every function of a translated program owns its parameter, local and
temporary slots (`docs/spec_call_return_conversion.md` §2), each call site a
return-address constant, each distinct constant a slot. Before the redesign
recorded in `docs/benchmarks.md` even the smallest example needed 620 slots;
`wasm-bench` needed 3042. The repository's earlier workaround, a
"big heap" asset with a hand-entered size (default 4096), moved the limit
but kept the failure mode: any program larger than the number typed in
failed the same way.

There is also a hard ceiling: `UdonHeap` silently clamps its capacity to
**1 048 576** slots.

## 3. Fix

Three parts, each sufficient for a class of programs:

1. **The translator needs far fewer slots.** Lazy operands, pooled
   temporaries, shared return registers, on-demand runtime state and dead
   function elimination cut heap use by 5–15× (`docs/benchmarks.md`). Small
   programs (`udon-orbit`: 68 slots) now assemble in the stock asset.

2. **The translator states the exact requirement.**
   `wasdon-zig translate --stats` prints it, `wasdon-zig check` recomputes
   it from the text, and the first line of every translation is

   ```
   # wasdon-zig heap-size: 712
   ```

   `Asm.Stats.heapSize()` is variables + distinct extern signatures — the
   same formula the assembler applies and UdonSharp uses for its own heap.
   A translation that needs more than 1 048 576 slots is rejected by the
   checker.

3. **The Unity program asset sizes the heap itself.**
   `WasdonProgramAsset` (`unity/Editor/`) assembles with a heap factory
   whose capacity is computed from the assembly text — it reads the
   `heap-size` line, and falls back to counting declarations and distinct
   string literals — so there is no number to enter and nothing to get
   wrong. It replaces `utils/BigHeapAssemblyProgramAsset.cs` and
   `utils/BigHeapWindow.cs` (which also defined the same class twice and
   could not coexist in one project).

## 4. Checking a program

```sh
$ wasdon-zig check program.uasm
program.uasm: 0 error(s)
  heap slots     712  (662 variables + 50 string literals; the stock assembler heap is 512)
  instructions   10338  (1870 EXTERN, 50 distinct signatures)
  code bytes     80228
```

The integration tests assert that the size the translator reports equals
the size the independent parser counts for every example.

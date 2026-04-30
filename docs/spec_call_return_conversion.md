# Call / Return Conversion Strategy

## 1. Problem

What WebAssembly requires:

- **Direct call** (`call $f`) — invoke a function by index.
- **Indirect call** (`call_indirect (type $t) $tableIdx`) — invoke through a function table.
- **Value-stack** based parameter and return-value passing.
- **Return** — function exit (both fall-through and early return).
- **Recursion** — nested invocation of the same function.

What the Udon VM does *not* provide (`docs/udon_specs.md` §1.1):

- `CALL` / `RET` instructions (no subroutine mechanism at all).
- Local variables (every variable is a data field on the heap).
- A value stack (the integer stack is merely plumbing for moving heap indices around).
- Runtime retrieval of a label's address (data initial values must be literals).

What the Udon VM *does* provide:

- `JUMP, <addr>` / `JUMP_INDIRECT, <var>` / `JUMP_IF_FALSE, <addr>`.
- `SystemUInt32` data variables initializable with integer literals (`docs/udon_specs.md` §4.7) — as discussed below, this is the *only* way to place a return address on the heap.
- The terminator address `0xFFFFFFFC` (`docs/udon_specs.md` §6.2.5).

Conclusion: the translator must **synthesize a calling convention (ABI) by hand**. This document defines that synthesis.

---

## 2. Terminology

| Term | Meaning |
|---|---|
| **Call frame** | The set of parameter / local / value-stack / return-value / return-address slots associated with one function invocation. |
| **RA slot** | A `SystemUInt32` data variable, one per function. The target read by `JUMP_INDIRECT`. |
| **RAC** (return-address constant) | A `SystemUInt32` constant data variable, one per call site. Its initial value is the bytecode address of the corresponding return-target label. |
| **Stackified pseudo-local** | A virtual local allocated per stack-depth, produced by analyzing the WASM value stack at compile time. |
| **Entry function** | A function mapped to a Udon event label via `__udon_meta.functions`; it is invoked by the Udon VM rather than by other WASM code. |

---

## 3. Per-Function ABI Layout

Extend the naming rules of `docs/spec_variable_conversion.md` with the suffixes below. The `__` prefix follows the existing rule.

| Role | Naming | Udon type | Count |
|---|---|---|---|
| Parameter | `__{fn}_P{i}__` | per WASM type | function arity |
| Local | `__{fn}_L{i}__` | (existing rule) | declared WASM locals |
| Stackified slot | `__{fn}_S{depth}__` | fixed per WASM type at each depth | maximum stack depth |
| Return value | `__{fn}_R{i}__` | per WASM return type | number of return values |
| RA slot | `__{fn}_RA__` | `SystemUInt32` | 1 |

In addition, per call site:

| Role | Naming | Udon type |
|---|---|---|
| RAC | `__ret_addr_{K}__` | `SystemUInt32` (initial value = bytecode address of the return target) |

`{K}` is a globally unique call-site index assigned by the translator.

**Important**: the slots above exist as *exactly one set per function* (in the non-recursive mode). See §8 for the recursive mode.

---

## 4. Translating a Direct Call

WASM side (pseudo-WAT, two arguments and one return value):

```wat
;; caller value stack: ... a0 a1 (top)
call $F
;; ... r (top)
```

Udon-side expansion:

```
# (a) Copy arguments from caller's S slots into callee's P slots
PUSH, __caller_S{n-1}__
PUSH, __F_P0__
COPY
PUSH, __caller_S{n}__
PUSH, __F_P1__
COPY

# (b) Copy this call site's RAC into __F_RA__
PUSH, __ret_addr_K__
PUSH, __F_RA__
COPY

# (c) Jump to the callee
JUMP, __F_entry__

# (d) Return target — this label's address is the literal stored in the RAC
__call_ret_K__:
    # (e) Copy the return value from the callee's R slot into the caller's S slot
    PUSH, __F_R0__
    PUSH, __caller_S{n-2}__
    COPY
```

Callee prologue / epilogue:

```
__F_entry__:
    # (f) If needed, copy P → L (in WASM, parameters and locals share the same
    #     index space, so an implementation that uses P{i} directly as L{i} is fine).
    ...
    # function body
    ...
__F_exit__:
    JUMP_INDIRECT, __F_RA__
```

Key points:

- `JUMP_INDIRECT, __F_RA__` reads the `__F_RA__` heap slot as `SystemUInt32` and jumps to that bytecode address (`docs/udon_specs.md` §6.2.8).
- The return target differs at each call site, so the call-site code overwrites `__F_RA__` immediately before `JUMP`-ing.
- `COPY` semantics: `PUSH src; PUSH dst; COPY` performs `dst ← src` (`docs/udon_specs.md` §6.2.9).

---

## 5. Hard-Coded RAC Generation (Address Computation)

Udon Assembly data initial values can only be literals; a label name cannot be used as an initial value (`docs/udon_specs.md` §4.5).
The translator must therefore **compute bytecode addresses itself** and emit each RAC as a literal.

### 5.1 Pass Structure

1. **Pass A — Layout determination.**
   Lower every function into an instruction stream with placeholder `__call_ret_K__` labels, summing instruction sizes (4 or 8 bytes; `docs/udon_specs.md` §6.1) in order to determine the bytecode address of every label.
2. **Pass B — Emit the data section.**
   Write each `__ret_addr_K__: %SystemUInt32, 0x????u` with the address determined in Pass A hard-coded as the literal.
3. **Pass C — Emit the code section.**
   Output the instruction stream using the layout fixed in Pass A.

### 5.2 Basic Properties of Addresses

- The first instruction's address is `0x00` (`docs/udon_specs.md` §9.1).
- Every instruction is 4 or 8 bytes, so the least-significant nibble of any label address is always one of `0` / `4` / `8` / `C`.
- The terminator `0xFFFFFFFC` is special — it is not an instruction address but a sentinel reserved for `JUMP`.

### 5.3 Possibility of a Single Pass

If the layout is fully determined at the time of instruction emission, Pass A and Pass C may be fused into a single pass (buffer the data section to a string and emit it later). This document does not mandate the implementation strategy.

---

## 6. Handling the WASM Value Stack (Stackification)

Since Udon has no runtime value stack, the WASM value stack is **resolved at compile time**:

- Walk the function body sequentially and track the value-stack depth at each instruction (the WASM validator guarantees this is statically determined).
- `i32.const` / `local.get` / etc. become assignments into `__{fn}_S{depth}__` at the current depth (via an anonymous `SystemInt32` followed by `COPY`, or a `COPY` from a local).
- Arithmetic instructions such as `i32.add` become `EXTERN` calls whose result is stored into the new top `S{d}` slot.
- Stack depth remains statically determined across blocks (`block` / `loop` / `if`), so allocating one fixed `S{d}` slot per depth is sufficient.

This way, step §4(a) at the call site is reduced to plain "copy caller's S slots into callee's P slots".

> Numeric WASM opcodes that read/write `S{d}` slots (arithmetic, comparisons, conversions, sign extension, etc.) are catalogued in `docs/spec_numeric_instruction_lowering.md`, which lists each opcode's EXTERN signature(s) and any synthesised multi-EXTERN sequence.

---

## 7. Indirect Call (`call_indirect`)

Reuse the `SystemObjectArray` pattern from `docs/spec_linear_memory.md`:

### 7.1 Function Table

- The WASM function table is represented in Udon as a `SystemUInt32Array` whose elements are the hard-coded bytecode addresses of each entry point `__{fn}_entry__`.
  - Using `SystemObjectArray` is also possible but requires an extra extern to unbox each element from `object` to `uint`. `SystemUInt32Array` is recommended for simplicity.
- Initialize the table itself in `_onEnable`, or at the start of an entry function, by calling `EXTERN, "SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array"` and using the typed-array indexer setter `SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid` (arguments `(index, value)`) to fill each slot with the corresponding `__{fn}_entry__` value. The inherited `Array.SetValue(object, int)` has no typed `UInt32` overload on `SystemUInt32Array`, so the indexer setter is the only available write node.
  - The entry-point address is fixed in Pass A, so the most ergonomic approach is to use a data variable `__fn_entry_addr_F__: %SystemUInt32, 0x????u` initialized with that literal and copy from it.

### 7.2 Translation

```
# the index sits at the top of the caller's S slots
PUSH, __fn_table__
PUSH, __caller_S{n}__               # index
PUSH, __indirect_target__           # output (out)
EXTERN, "SystemUInt32Array.__Get__SystemInt32__SystemUInt32"

# Argument copy (same as §4 (a))
...

# RAC setup — but use the shared __indirect_RA__ slot rather than a per-callee
# __F_RA__, because the callee is not known at compile time.
PUSH, __ret_addr_K__
PUSH, __indirect_RA__
COPY

JUMP_INDIRECT, __indirect_target__
__call_ret_K__:
    # Return-value copy (§4 (e))
    ...
```

### 7.3 Shared RA Slot Design

A function reachable through `call_indirect` must read its return address from a **globally shared `__indirect_RA__`** rather than from `__F_RA__` (since the caller cannot know the callee at compile time). Implementation:

- Emit indirect-callable functions under the "indirect convention" as well, giving them an alternative exit `__F_exit_indirect__: JUMP_INDIRECT, __indirect_RA__`.
- Functions called only directly need only the `__F_RA__` version.
- Functions called both ways need both exits (the caller selects which exit/RA-slot pair to use).

### 7.4 Type Checking

WASM's `call_indirect` validates the signature at runtime. Reproducing this faithfully in Udon is expensive, so it is **omitted by default**: the translator classifies entries in the table by signature at translation time and rejects mismatches as a translation error. Future activation may be exposed via `__udon_meta.options`.

### 7.5 `call_indirect` with explicit table index (reference-types)

The post-MVP `reference-types` proposal generalises the trailing
reserved byte of `call_indirect` into a varuint **table index**:

```text
call_indirect typeidx:uleb128 table_idx:uleb128
```

See `docs/w3c_wasm_binary_format_note.md` §"`call_indirect` under the
`reference-types` proposal" for the binary-format change. This
subsection covers what the translator does with the parsed value.

#### Decoder

The instruction's payload is no longer a single `u32` (the type index)
plus an asserted-zero byte; it is the pair
`CallIndirectArgs { typeidx: u32, table_idx: u32 }`, both decoded as
ULEB128 `u32`s.

#### Backwards compatibility

MVP fixtures where the table index is implicitly `0` parse identically
under the new decoder, because `uleb128(0)` is exactly the single byte
`0x00`. Every Core 1 `call_indirect` therefore round-trips through the
generalised decoder without any producer-side change.

#### Lowering — only `table_idx == 0` is supported

The translator's lowering pass requires `args.table_idx == 0`. Any
other value returns `error.MultiTableNotYetSupported` with a clear
diagnostic identifying the offending function and call site.

Rationale: with a single function table, the existing
`__fn_table__` global (see §7.1) suffices, and the per-call lowering
in §7.2 is unchanged. Multi-table support would require:

1. Per-table fields (e.g. `__fn_table_<n>__: %SystemUInt32Array`),
   each populated at startup from its corresponding WASM `element`
   segment.
2. A per-call dispatch that selects the correct `__fn_table_<n>__`
   based on `args.table_idx` — straightforward but mechanical.
3. Recursion-checker / signature-checker tweaks so that table
   classification (§7.4) is per-table.

None of these are conceptually difficult, but they were deferred
because the producers the translator supports today
(`wasm32v1-none` Rust, MVP-pinned Zig, hand-rolled WAT) only ever
emit a single function table. The opt-in `reference-types`
fixtures in `examples/post-mvp/reference-types-funcref/` therefore
all use `table_idx == 0`.

#### Producer-side note

Producers that opt into the `reference-types` proposal (typically by
passing `--enable-reference-types` to `wat2wasm`) must keep the
target table index at `0` until multi-table support lands. See
`docs/producer_guide.md` for the toolchain incantations.

---

## 8. Recursion

The §3 layout assumes "exactly one frame per function". Recursion would overwrite the live frame and break the program. Two modes are provided.

### 8.1 `recursion: "disabled"` (default)

- The translator builds the call graph and warns or errors when it detects a strongly connected component (SCC).
- The behavior switches between `ignore | warn | error` at the same granularity as `__udon_meta.options.unknownFunctionPolicy`.
- Frames remain a single static layout per function. Maximum performance.

### 8.2 `recursion: "stack"` (opt-in)

- For recursive functions (those in an SCC), the prologue / epilogue pushes / pops the entire frame onto a `SystemObjectArray`-based stack.
- Reuse the `SystemObjectArray` pattern from `docs/spec_linear_memory.md` — allocate dedicated `__call_stack__: %SystemObjectArray` and `__call_stack_top__: %SystemInt32`.
- Prologue: push every P / L / S / R / RA onto `__call_stack__` (one EXTERN call per element).
- Epilogue: restore them and `JUMP_INDIRECT, __F_RA__`.
- The cost is significant but correctness is guaranteed.

### 8.3 Proposed `__udon_meta` Extension

This document proposes adding the following to the `options` field of `docs/spec_udonmeta_conversion.md`:

```json
{
  "options": {
    "recursion": "disabled"  // "disabled" | "stack"
  }
}
```

When unspecified, the default is `"disabled"`.

---

## 9. The `return` Instruction

WASM's `return` (early function exit) expands as follows:

```
# (If a return value exists) copy S → R
PUSH, __F_S{n}__
PUSH, __F_R0__
COPY

JUMP, __F_exit__
```

`__F_exit__` joins the tail in §4. Natural fall-through (control reaching the end of the WASM function) is translated identically — place the function tail immediately before the `__F_exit__` label.

**Dead-code fall-through.** When the body ends with `unreachable`, an unconditional branch out of the function, or a `return` followed by dead code, the abstract value-stack at the textual end of the body may not actually contain `result_arity` entries — the validator treats the stack as polymorphic in that region, but the translator tracks concrete depth. The fall-through result-copy is dead in that case (the function trapped or returned earlier), so the translator emits the `__F_exit__` label and the indirect jump but **omits the `S → R` copy** when concrete `depth < result_arity`. This is observable as a missing tail-copy stanza in the lowered assembly for functions whose last instruction is `unreachable`; the program is correct because that copy can never execute.

---

## 10. Entry-Point Functions (Mapped to Udon Events)

Functions mapped via `docs/spec_udonmeta_conversion.md`'s `functions` to Udon event labels (`_start` / `_update` / `_interact` / etc.) are **never called from WASM**; they are launched by the Udon VM's event dispatcher:

- They have no `__F_RA__` or `__ret_addr_K__`.
- They terminate with `JUMP, 0xFFFFFFFC` (`docs/udon_specs.md` §6.2.5).
- The label receives `.export <label>` (`docs/udon_specs.md` §5.3 / §8.1).
- Standard-event arguments are placed in the dedicated variables described in `docs/udon_specs.md` §8.2 and wired up through `__udon_meta.fields`.

If an entry function is itself the *caller* of another WASM function, normal call-site expansion per §4 still applies.

---

## 11. Complete Worked Example

### 11.1 Input WASM (pseudo-WAT)

```wat
(module
  (func $add (param $a i32) (param $b i32) (result i32)
    local.get $a
    local.get $b
    i32.add)
  (func $start
    i32.const 3
    i32.const 4
    call $add
    drop)
  (export "_start" (func $start)))
```

`__udon_meta` excerpt:

```json
{
  "functions": {
    "start": { "source": { "kind": "export", "name": "_start" },
               "label": "_start", "export": true, "event": "Start" }
  }
}
```

### 11.2 Address Computation (Pass A Result)

Placing `_start` first followed by `add`, accumulating instruction sizes (`docs/udon_specs.md` §6.1) yields the following addresses:

| Position | Address | Instruction |
|---|---|---|
| `_start:` | `0x00` | (label) |
|  | `0x00` | `PUSH, __const_3__` |
|  | `0x08` | `PUSH, __start_S0__` |
|  | `0x10` | `COPY` |
|  | `0x14` | `PUSH, __const_4__` |
|  | `0x1C` | `PUSH, __start_S1__` |
|  | `0x24` | `COPY` |
|  | `0x28` | `PUSH, __start_S0__` |
|  | `0x30` | `PUSH, __add_P0__` |
|  | `0x38` | `COPY` |
|  | `0x3C` | `PUSH, __start_S1__` |
|  | `0x44` | `PUSH, __add_P1__` |
|  | `0x4C` | `COPY` |
|  | `0x50` | `PUSH, __ret_addr_0__` |
|  | `0x58` | `PUSH, __add_RA__` |
|  | `0x60` | `COPY` |
|  | `0x64` | `JUMP, __add_entry__` |
| `__call_ret_0__:` | **`0x6C`** | (label — this is the literal stored in the RAC) |
|  | `0x6C` | `PUSH, __add_R0__` |
|  | `0x74` | `PUSH, __start_S0__` |
|  | `0x7C` | `COPY` |
|  | `0x80` | `JUMP, 0xFFFFFFFC` |
| `__add_entry__:` | **`0x88`** | (label) |
|  | `0x88` | `PUSH, __add_P0__` |
|  | `0x90` | `PUSH, __add_S0__` |
|  | `0x98` | `COPY` |
|  | `0x9C` | `PUSH, __add_P1__` |
|  | `0xA4` | `PUSH, __add_S1__` |
|  | `0xAC` | `COPY` |
|  | `0xB0` | `PUSH, __add_S0__` |
|  | `0xB8` | `PUSH, __add_S1__` |
|  | `0xC0` | `PUSH, __add_S0__` |
|  | `0xC8` | `EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"` |
|  | `0xD0` | `PUSH, __add_S0__` |
|  | `0xD8` | `PUSH, __add_R0__` |
|  | `0xE0` | `COPY` |
| `__add_exit__:` | `0xE4` | (label) |
|  | `0xE4` | `JUMP_INDIRECT, __add_RA__` |

(The `i32.add` extern signature shown is illustrative. The actual signature should be confirmed via the UdonSharp Class Exposure Tree or Udon Graph — see `docs/udon_specs.md` §7.5.)

Important addresses produced:

- `__call_ret_0__` = `0x0000006C`
- `__add_entry__` = `0x00000088`

### 11.3 Output Udon Assembly

```
.data_start
    # WASM constants
    __const_3__:        %SystemInt32, 3
    __const_4__:        %SystemInt32, 4

    # _start function's stackified slots
    __start_S0__:       %SystemInt32, 0
    __start_S1__:       %SystemInt32, 0

    # add function's P / S / R / RA
    __add_P0__:         %SystemInt32, 0
    __add_P1__:         %SystemInt32, 0
    __add_S0__:         %SystemInt32, 0
    __add_S1__:         %SystemInt32, 0
    __add_R0__:         %SystemInt32, 0
    __add_RA__:         %SystemUInt32, 0

    # Call site 0's RAC (return address computed in Pass A)
    __ret_addr_0__:     %SystemUInt32, 0x0000006C
.data_end

.code_start
    .export _start
    _start:
        # i32.const 3 → S0
        PUSH, __const_3__
        PUSH, __start_S0__
        COPY
        # i32.const 4 → S1
        PUSH, __const_4__
        PUSH, __start_S1__
        COPY

        # call $add: argument passing
        PUSH, __start_S0__
        PUSH, __add_P0__
        COPY
        PUSH, __start_S1__
        PUSH, __add_P1__
        COPY

        # RA setup
        PUSH, __ret_addr_0__
        PUSH, __add_RA__
        COPY

        # Jump to callee
        JUMP, __add_entry__

    __call_ret_0__:
        # Receive return value
        PUSH, __add_R0__
        PUSH, __start_S0__
        COPY
        # WASM `drop` emits nothing
        JUMP, 0xFFFFFFFC

    __add_entry__:
        # local.get $a → S0
        PUSH, __add_P0__
        PUSH, __add_S0__
        COPY
        # local.get $b → S1
        PUSH, __add_P1__
        PUSH, __add_S1__
        COPY
        # i32.add: result → S0
        PUSH, __add_S0__
        PUSH, __add_S1__
        PUSH, __add_S0__
        EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
        # Natural fall-through return: S0 → R0
        PUSH, __add_S0__
        PUSH, __add_R0__
        COPY
    __add_exit__:
        JUMP_INDIRECT, __add_RA__
.code_end
```

If the translator adds or removes a single instruction, `__call_ret_0__`'s address changes. Pass A → Pass B ordering must therefore be preserved strictly.

---

## 12. Constraints and Cautions

- **RAC must be a named variable.** Anonymous variables created from string literals (`docs/udon_specs.md` §10) produce `SystemString` and cannot be used for `SystemUInt32`. RACs and function-table elements must be declared explicitly in the data section.
- **EXTERN's optimization cache.** The heap slot referenced by an `EXTERN` parameter is overwritten by optimization-cache data on first execution (`docs/udon_specs.md` §6.2.6, §12). Never share a RAC slot or RA slot with an `EXTERN` parameter.
- **Avoid `Address aliasing detected`.** When two consecutive labels (e.g. `__call_ret_K__` and the very next function's entry) collide on the same address, insert a `NOP` to shift by 4 bytes (`docs/udon_specs.md` §5.2).
- **Notation for `0xFFFFFFFC`.** Both as a `JUMP` immediate and as a data initial value, write it without a suffix as `0xFFFFFFFC` — the matching form for `JUMP` immediates per `docs/udon_specs.md` §11.1 and the only form accepted in `%SystemUInt32` data initializers (the `u` suffix is rejected by the lexer; see `docs/udon_specs.md` §4.7).
- **Initial-value restrictions on return-value slots.** `SystemInt64` / `SystemUInt64` / `SystemSByte` / `SystemByte` / `SystemInt16` / `SystemUInt16` / `SystemBoolean` cannot be initialized to anything but `null` (`docs/udon_specs.md` §4.7, §12). Such return values must be initialized to `null` and assumed to be filled by the first `COPY`. In particular, the translator must guarantee that a boolean return value is assigned before any `JUMP_IF_FALSE` reads it.
- **Floating-point precision.** `SystemDouble` data initial values are read at `float` precision (`docs/udon_specs.md` §4.7). WASM `f64` constants therefore should not be stored as data initial values; assemble them via EXTERN if needed.
- **Optimizations that mutate the instruction stream.** Such optimizations would shift label addresses; do not modify the code after Pass A's address determination. If you must, all RACs and function-table elements must be recomputed.

---

## 13. Alignment with and Extensions to Existing Specs

- Add to the naming rules of `docs/spec_variable_conversion.md` the suffixes **`P{i}` / `S{depth}` / `R{i}` / `RA`**, plus the call-site-level names `__ret_addr_{K}__` / `__call_ret_{K}__`. The other spec must be amended at implementation time.
- Add **`recursion: "disabled" | "stack"`** to the `options` field of `docs/spec_udonmeta_conversion.md` (§8.3).
- The `SystemObjectArray` pattern of `docs/spec_linear_memory.md` is reused as-is for (a) the function table (in its `SystemUInt32Array` variant) and (b) the call-stack implementation in `recursion: "stack"` mode.

---

## 14. Open Issues

- Confirming the exact extern signatures for `i32.add` and other arithmetic — extraction from the UdonSharp Class Exposure Tree is required.
- Precise mappings for `SystemInt64` / `f64` / `funcref` / `externref` — Udon's type support is limited; the initial implementation may leave these unsupported or defer them to a separate spec.
- Handling of the WASM `start` section (module-startup function) — to be specified, e.g. dispatched via `_onEnable`.
- Initialization timing for memory (`data` segments) and the function table (`element` segments) — assumed to be a one-shot initialization in `_onEnable` or at the start of an entry function.

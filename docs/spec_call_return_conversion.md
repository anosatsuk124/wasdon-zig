# Functions, Calls, Returns and Control Flow

## 1. Problem

WebAssembly has functions with parameters, locals, an operand stack,
structured control flow, direct and indirect calls, and recursion. The Udon
VM (`docs/udon_specs.md`, `docs/udon_vm.md`) has:

- three jumps — `JUMP`, `JUMP_IF_FALSE`, `JUMP_INDIRECT` — and no call or
  return;
- no local variables and no value stack: every value is a heap slot, and
  the integer stack only carries heap indices to the next instruction;
- data initializers that are literals, so a code address can only get into
  the heap as a literal the translator computed.

The translator synthesizes a calling convention on top of that. This
document defines it. The implementation is `src/translator/translate.zig`
(module level) and `src/translator/lower.zig` (function bodies).

## 2. Frames

Each reachable function owns a fixed set of heap slots:

| Slot | Name | Type |
|---|---|---|
| parameter *i* | `__{fn}_P{i}__` | by WASM type |
| declared local *i* (index continues after the parameters) | `__{fn}_L{i}__` | by WASM type |
| temporary | `__{fn}_T{n}__` | whatever the value needs |
| return address (only in `indirect` mode, §4) | `__{fn}_RA__` | `SystemUInt32` |

`{fn}` is the function's export name, else its name from the `name` section,
else `f{index}`; sanitized to letters, digits and `_`.

There is exactly one frame per function, not one per activation. That is
sound as long as a function is active at most once; §6 covers the functions
for which that is not true.

**Unreachable functions get no frame and no code.** Reachability starts at
the functions bound to Udon events and the WASM start function and follows
direct calls and, for `call_indirect`, every table entry of the called type.

**Locals are zero-initialized only when needed.** WASM zeroes declared
locals on every call; slots keep their previous value. A single pass finds
the locals that can be read before any assignment on some path, and only
those are reset at function entry.

## 3. The operand stack

The WASM operand stack is resolved at translation time. Each stack entry
records where the value can be *read*:

| Entry | Value is in | Becomes invalid when |
|---|---|---|
| constant | a constant slot (`docs/spec_numeric_conversion.md` §5) | never |
| local | the local's own slot | the local is assigned |
| shared | a global, a return register, a field | a call, or an assignment to it |
| temporary | a temporary owned by the entry | the entry is consumed |
| condition | a `SystemBoolean` holding a comparison result | (as temporary / shared) |

`local.get`, `global.get` and constants emit **no code**; they push an
entry. Code is emitted when a value is computed, and reads operand slots
directly:

```wat
local.get $a          ;; entry: local a
local.get $b          ;; entry: local b
i32.add               ;; PUSH a; PUSH b; PUSH T1; EXTERN add     entry: temporary T1
local.set $c          ;; retarget the add's result slot: PUSH T1 → PUSH c
```

Result: `PUSH a; PUSH b; PUSH c; EXTERN "SystemInt32.__op_Addition__…"` —
four instructions.

Three rules keep this correct:

1. **Detach before overwrite.** Before a local, global or field is
   assigned, entries that still refer to it are copied to temporaries.
   Before a call, entries that refer to shared slots are.
2. **Joins use agreed slots.** Values that flow into the end of a `block` /
   `if` from more than one place are moved into join temporaries owned by
   that block; lazy entries never cross a block entry (everything below a
   `block` / `loop` / `if` that could be invalidated inside it is detached
   first, because a write in one arm cannot be compensated in the other).
3. **Retarget only the last instruction.** An entry remembers the `PUSH`
   that named its temporary as an extern's result. The destination is
   rewritten (to a local, a parameter slot, a join slot, a return register)
   only if that extern is still the last instruction emitted.

Temporaries are pooled per function and per Udon type and reused as soon as
their entry is consumed, so a slot is only ever used at one type
(`docs/udon_vm.md` §3).

## 4. Calls and returns

### Return modes

| Mode | When | Callee returns with | Caller sets up |
|---|---|---|---|
| `halt` | only Udon events call the function | `JUMP, 0xFFFFFFFC` | nothing |
| `direct` | exactly one call site, not in the function table | `JUMP` to the label after that call site | nothing |
| `indirect` | everything else | `JUMP_INDIRECT, __{fn}_RA__` | `COPY` a return-address constant into `__{fn}_RA__` |

A **return-address constant** is a `SystemUInt32` variable `__ra_{N}` whose
initial value is the bytecode address of the label after the call. Layout
runs after all code is emitted and optimized, so the literal is always the
final address.

### Direct call

```
# arguments: caller operands → callee parameter slots
PUSH, <arg0>       PUSH, __callee_P0__     COPY
...
PUSH, __ra_7       PUSH, __callee_RA__     COPY        # indirect mode only
JUMP, <callee entry>
<return lands here>
```

The last argument is passed first; if it was just computed, its computation
writes the parameter slot directly (§3 rule 3) and no `COPY` is emitted.

### Results

A function leaves result *k* in the **return register** `__ret{k}_{type}`
(shared by all functions). After a call the result is a *shared* entry: the
next instruction usually consumes it straight from the register; it is
copied to a temporary only if another call intervenes. Returning a value
that was just computed retargets the computation to the register.

### `call_indirect`

- The function table is a `SystemUInt32Array` of entry addresses, built by
  the init routine from one Base64 string (`__table_b64`, whose contents are
  the little-endian addresses, filled in at layout time) with
  `FromBase64String` + `Buffer.BlockCopy` — three externs for any table
  size.
- Arguments go to shared slots `__ia{k}_{type}`, the return address to
  `__ind_RA`, then `JUMP_INDIRECT` through the looked-up address.
- Each table function has a **trampoline** that copies `__ia*` into its own
  parameter slots and `__ind_RA` into its `__{fn}_RA__`, then jumps to its
  entry. Table functions always use `indirect` mode.
- Empty table slots hold the address of the trap routine. An out-of-range
  index raises a .NET exception in the lookup. Signature mismatch is **not**
  checked at run time.

The table, trampolines and shared slots are only emitted if some reachable
function performs an indirect call.

## 5. Control flow

| WASM | Udon |
|---|---|
| `block` | label at the end; branches jump to it |
| `loop` | label at the start; branches jump to it |
| `if` / `else` | `PUSH cond; JUMP_IF_FALSE else`, then arm, `JUMP end`, else arm |
| `br` | move carried values to the target's join slots, `JUMP` |
| `br_if` (no values) | `PUSH !cond; JUMP_IF_FALSE target` |
| `br_if` (values / return) | `PUSH cond; JUMP_IF_FALSE skip`, copy values, `JUMP target` |
| `br_table` | one equality test per non-default case |
| `return` | results to return registers, then return (§4) |
| `unreachable` | `JUMP` to the trap routine (logs an error, ends the event) |

Code after an unconditional branch is not lowered.

**Comparisons stay Boolean.** A comparison produces a `SystemBoolean`
*condition* entry. `if`, `br_if` and `select` consume it directly; `i32.eqz`
of a condition only flips a flag. Where a consumer needs the opposite sense
and the comparison is still the last instruction, the comparison's extern is
swapped for its inverse (`<` ↔ `≥`, …; for floats only `==` ↔ `!=`, because
the others differ on NaN) instead of negating at run time. A condition is
converted to `Int32` (`Convert.ToInt32(Boolean)`) only if it is used as a
number. Compare-and-branch is therefore one extern plus `PUSH` and
`JUMP_IF_FALSE`.

After emission, `Asm.optimize` threads jumps to jumps, removes jumps to the
next instruction, and drops instructions no jump or fall-through can reach.

## 6. Recursion

A function on a call-graph cycle can be active more than once, and its
single frame (§2) would be overwritten. The call graph is built from direct
calls plus, for each `call_indirect`, every table function of that type;
its strongly connected components identify such functions.

With `options.recursion = "stack"` (the default), a call from function *f*
to a function in *f*'s own component **saves *f*'s frame around the call**:

```
for each live slot s of f:   __call_stack[top] = s;  top += 1
<pass arguments, call>
for each slot in reverse:    top -= 1;  s = __call_stack[top]
```

The saved slots are *f*'s parameters and locals, the temporaries of operands
still on the stack below the arguments, join slots of enclosing blocks, and
`__{fn}_RA__`. Saving is done by the caller, before the arguments are
written, because for a self-call the arguments overwrite the very
parameters being saved. `__call_stack` is a `SystemObjectArray` of
`options.callStackSize` slots (default 4096); overflowing it raises a .NET
exception.

Calls to functions outside the component cost nothing extra, and
non-recursive programs do not get a `__call_stack` at all.

`options.recursion = "disabled"` suppresses all saving. It is only correct
if no function is ever actually re-entered; it exists for programs where
indirect calls make the conservative call graph look cyclic.

## 7. Events and initialization

A function bound to an Udon event (`docs/spec_udonmeta_conversion.md`) gets
an exported label:

```
.export _update
_update:
    PUSH, __inited
    JUMP_IF_FALSE, <init stub for this event>
    <enter the function: JUMP, or COPY __ra_halt → RA and JUMP>
```

`__ra_halt` holds `0xFFFFFFFC`, so an `indirect`-mode function bound to an
event returns straight out of the VM.

**Initialization runs before the first event, whichever it is.** Every
event entry tests `__inited` (a `SystemBoolean`, false until set) and
detours through the init routine once. Nothing depends on Udon delivering
`_onEnable` or `_start` first, and re-enabling the object does not
re-initialize. The init routine, in order:

1. sets `__inited`;
2. allocates linear memory and copies the data segments
   (`docs/spec_linear_memory.md` §8);
3. decodes the constant pool and reads out the constants that cannot be
   literals (`docs/spec_numeric_conversion.md` §5);
4. allocates the store arrays, the UTF-8 encoding object, the call stack
   and the function table — each only if used;
5. assigns globals whose initial value is not a literal;
6. writes memory-backed fields into memory;
7. calls the WASM start function, if the module has one.

Event functions must take no parameters; results are ignored.

**Nested events.** `SendCustomEvent` on the behaviour itself runs the target
event inside the current one. Because frames are static, the nested event
must not reach a function that is active in the outer one.

## 8. Limits

- Multi-value blocks with parameters are not supported; multiple function
  results are.
- `call_indirect` does not check signatures.
- Element segments must have constant offsets; passive and declarative
  element segments are ignored.
- `br_table` is a linear chain of comparisons.

# Numeric Conversion

How WASM's numeric instructions map to Udon externs. Udon has no arithmetic
of its own: every operation is an `EXTERN` on a .NET method, each slot holds
a value of one .NET type, and a slot can only be read as the type it was
last written with (`docs/udon_vm.md` §3).

## 1. Representation

| WASM type | Udon type |
|---|---|
| `i32` | `SystemInt32` |
| `i64` | `SystemInt64` |
| `f32` | `SystemSingle` |
| `f64` | `SystemDouble` |

There are no unsigned slots. WASM integers are sign-agnostic bit patterns;
keeping them all in the signed .NET types means no value ever has to be
moved between `Int32` and `UInt32` (which would need `BitConverter.GetBytes`
plus `BitConverter.ToUInt32` — two externs and an allocation — per
operand). Unsigned operations are computed in the signed domain (§3).

Comparison results are `SystemBoolean` and stay that way until used as a
number (`docs/spec_call_return_conversion.md` §5).

## 2. Direct mappings

One extern each.

| WASM | Extern |
|---|---|
| `add sub mul` (all types) | `op_Addition` `op_Subtraction` `op_Multiplication` |
| `i32/i64.div_s`, `f32/f64.div` | `op_Division` |
| `and or xor` | `op_LogicalAnd` `op_LogicalOr` `op_LogicalXor` |
| `shl`, `shr_s` | `op_LeftShift`, `op_RightShift` (count is `Int32`) |
| `eq ne lt_s le_s gt_s ge_s`, float comparisons | `op_Equality` … `op_GreaterThanOrEqual` |
| `eqz` | `op_Equality` with constant 0 |
| `f32.abs neg sqrt ceil floor nearest min max` | `Math.Abs`, `op_UnaryMinus`, `Mathf.Sqrt/Ceil/Floor/Round`, `Math.Min/Max` |
| `f64.abs neg sqrt ceil floor trunc nearest min max` | `Math.Abs`, `op_UnaryMinus`, `Math.Sqrt/Ceiling/Floor/Truncate/Round/Min/Max` |
| `i64.extend_i32_s` | `Convert.ToInt64(Int32)` |
| `f32/f64.convert_i32_s/i64_s` | `Convert.ToSingle/ToDouble` |
| `f32.demote_f64`, `f64.promote_f32` | `Convert.ToSingle(Double)`, `Convert.ToDouble(Single)` |
| `reinterpret` | `BitConverter.SingleToInt32Bits`, `Int32BitsToSingle`, `DoubleToInt64Bits`, `Int64BitsToDouble` |

.NET integer operators wrap, and shift operators mask the count to the
operand width — both as WASM requires. `Math.Round` rounds half to even, as
`nearest` requires. Udon exposes no `op_OnesComplement`; compilers emit
`xor -1` for bitwise not, which maps directly.

Integer operations on two constants are folded, and operations with an
identity operand (`x + 0`, `x * 1`, `x & -1`, shifts by 0) emit nothing.

## 3. Unsigned operations in the signed domain

Each stack entry carries a *non-negative* flag: set for non-negative
constants, results of `load8_u` / `load16_u`, logical shifts by a constant
≥ 1, `and` with a non-negative operand, comparison results, `memory.size`.
When both operands are known non-negative the signed operation is used
unchanged.

A local remembers the flag of the value last assigned to it, so the
knowledge survives `local.set` / `local.get` — but only along straight-line
code: every label clears it for all locals, since other paths reach the
label with other values. Declared locals start non-negative (they start at
zero); parameters do not.

The sign-flipped form of a local is kept in the derived-value cache
(`docs/spec_linear_memory.md` §5), so comparing the same local unsigned
several times flips it once.

**Masks merge.** `(x & m) & c` with constant `m` and `c` is emitted as one
`&` with `m & c`: when the second `&` arrives and the first is still the
last instruction, its constant operand is replaced. This is what
`(x >>> k) & c` — a bit-field extraction — turns into, the logical shift
being an arithmetic shift and a mask. For commutative operators a constant
operand is moved to the right first, so `c & x` is recognized too.

| WASM | Lowering | Externs |
|---|---|---:|
| `lt_u le_u gt_u ge_u` | flip the sign bit of both operands (`xor MIN`), then the signed comparison; a constant operand is flipped at translation time | 1–3 |
| `shr_u` by constant *c* | `(a >> c) & (ALL >>> c)` | 2 |
| `shr_u` by variable *n* | `(a >> n) & ~((MIN >> n) << 1)` | 5 |
| `rotl`, `rotr` | two shifts and an `or` | 4–9 |
| `i32.div_u`, `i32.rem_u` | zero-extend both to `Int64`, signed 64-bit divide / `Math.DivRem`, truncate | 5–8 |
| `i64.div_u`, `i64.rem_u` | signed division with fix-ups for operands ≥ 2⁶³ | branches |
| `i64.extend_i32_u` | `Convert.ToInt64(Int32)` then `& 0xFFFFFFFF` | 2 |
| `f32/f64.convert_i32_u` | zero-extend to `Int64`, signed convert | 3 |
| `f32/f64.convert_i64_u` | signed convert; values ≥ 2⁶³ are halved (sticky low bit), converted, doubled | branch |

## 4. Operations that need care

**`i32.wrap_i64`.** `Convert.ToInt32(Int64)` is range-checked and throws.
The low half is sign-extended in place first: `(x << 32) >> 32`, then
`Convert.ToInt32`. Three externs, no allocation.

**Float → integer.** `Convert.ToInt32(Double)` *rounds to nearest even*;
WASM truncates. Truncation is explicit: `Math.Truncate(x)`, then
`Convert.ToInt32` / `ToInt64`. `f32` sources are promoted to `f64` first
(exact). Unsigned targets go through the signed 64-bit conversion.
Out-of-range and NaN inputs make `Convert` throw, which halts the
behaviour, matching the WASM trap. The saturating forms
(`trunc_sat_*`) test for NaN and the bounds first and never throw.

**Signed remainder.** `SystemInt32.op_Remainder` exists; `Int64` has none
and uses `Math.DivRem`. .NET throws on `MIN % -1` where WASM yields 0, so a
divisor that is not a constant is compared with −1 first. A constant divisor
needs no test.

**`i64` shift counts.** WASM passes an `i64` count; .NET takes `Int32`. A
constant count is converted at translation time; a variable one is masked to
6 bits and converted with `Convert.ToInt32(Int64)`.

**`clz`, `ctz`, `popcnt`.** No .NET counterpart is exposed. `clz` and `ctz`
read the exponent of the operand converted to `double`
(`1054 − exponent` for `clz`; the lowest set bit is isolated with `x & −x`
for `ctz`); `popcnt` is the usual parallel bit count. The 64-bit forms
split into halves.

**`copysign`, `f32.trunc`, sign-extension operators.** `copysign` combines
the reinterpreted bit patterns; `f32.trunc` goes through `f64`
(`Math.Truncate` has no `Single` overload in Udon); sign extension is a
shift left followed by an arithmetic shift right.

Everything in this section and the multi-step rows of §3 is written as a
sequence of simpler WASM instructions (`snippets` in
`src/translator/lower.zig`) and lowered through the same code as user code,
so constant folding and result retargeting apply to it too.

### Known deviations from WASM semantics

- `min` / `max` of `−0` and `+0` return whichever .NET's `Math.Min/Max`
  returns, which is not always the WASM-specified zero.
- NaN payloads follow .NET, not WASM's canonicalization rules.
- `i32.trunc_f*_u` and `i64.trunc_f*_u` accept slightly out-of-range inputs
  that WASM would trap on (they wrap instead).
- Integer division by zero and `MIN / −1` raise .NET exceptions, which halt
  the UdonBehaviour rather than only the current event.

## 5. Constants

Udon Assembly can only initialize `SystemInt32`, `SystemUInt32`,
`SystemSingle` and `SystemString` variables with literals, and reads float
literals at `float` precision (`docs/udon_specs.md` §4.7).

| Constant | Variable | Initialized by |
|---|---|---|
| `i32` | `__c_i32_{value}` | literal |
| `f32` whose decimal form is exact | `__c_f32_{bits}` | literal |
| other `f32`, `i64`, `f64` | `__c_{type}_{bits}` | the init routine |
| zero of `i64` / `f64` | `__c_i64_0`, `__c_f64_0` | `null` (the type's default) |

Constants are shared across the whole program.

**The constant pool.** All constants that cannot be literals are packed,
little-endian, into one byte string and emitted as a single Base64 literal:

```
__kpool_b64: %SystemString, "<Base64>"
```

The init routine decodes it once (`Convert.FromBase64String` → `__kpool`)
and reads each constant with `BitConverter.ToInt64 / ToSingle / ToDouble
(__kpool, offset)` — one extern per constant, bit-exact, with no dependence
on how the assembler parses numbers. Constant *stores* copy their bytes
straight from the pool (`docs/spec_linear_memory.md` §4).

An `f32` constant is written as a literal only when its shortest decimal
representation denotes exactly that float (`0.5`, `1.5`, `100`), so that
any correctly or incorrectly rounding parser reads the same value.

## 6. Counted loops

For an innermost i32 countdown with a second cursor advancing by one
on every iteration, the translator computes the final cursor before
the loop. Comparing against that value replaces the count update and
zero test. The identity also holds for a wrapping cursor or count.
A count read elsewhere, an early branch bypassing the latch, or an
additional write prevents this transformation.

An induction variable used only as `base + i`, in constant increments
and in equality tests against a fixed limit can hold the address
directly. The limit receives the same offset before the loop. For an
unsigned ordering comparison, the offset is instead the i32 sign bit
and the comparison uses signed order. The base receives the opposite
offset, preserving addresses modulo 2^32. The translator restores a
cursor's original representation when it is live after the loop.

For a unit-stride cursor, the translator also follows control flow with
the condition `i < limit` assumed false. If no increment is reachable
on that path, an unsigned less-than test is equivalent to inequality
against a fixed sentinel. The sentinel is initially `max_u(i, limit)`,
so a cursor that starts past the limit stays put. Both cursor and
sentinel can then use absolute addresses.

For small innermost loops the translator can generate multiple versions
of a basic block. Each entry records which numeric comparisons were
true or false on the incoming edge. Writing either operand invalidates
the fact. A repeated comparison can disappear only when its Boolean
result is a dead scratch slot and the branch is its sole consumer.
Only direct control flow and known numeric operators and array accessors
are eligible. Array accesses retain their order. Unknown calls, escaping
edges or exceeding the code-size budget leave the original loop intact.

Nontrapping integer arithmetic on constants and unmodified locals can
execute once in a loop preheader. This includes the sign-bit flip for
unsigned order and constant address offsets. The outermost call-free
loop in which both operands are invariant owns the result. Divisions,
remainders and loads retain their execution order. A backedge skips the
preheader, while entry from an enclosing block executes it. Sibling
loops may share result slots, and nested loops use distinct slots.

An equality on a unit-stride induction variable can also stay unequal
for a bounded number of iterations. When the variable is tested before
its one possible increment, a positive modular distance of `d` to an
invariant limit guarantees at least `d` unequal tests. A counted loop
can use the minimum of these distances and its remaining trip count to
run groups of four iterations with the proven outcomes. The outer check
runs again after that group range. A short or negative distance enters
the original scalar control flow. This transformation requires a single
backedge and an unconditional update of the primary induction variable.
It makes no assumptions about the contents of linear memory.

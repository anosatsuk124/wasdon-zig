# Numeric instruction lowering

## §1 Overview
WASM numeric instructions lower to Udon EXTERN calls on the corresponding .NET primitive types (`SystemInt32`, `SystemInt64`, `SystemSingle`, `SystemDouble`, …). Most ops route through the lookup table in `src/translator/lower_numeric.zig`. Some require synthesised multi-EXTERN sequences.

## §2 MVP arithmetic via `lower_numeric.zig`
(Reference list. To be expanded.)

## §3 Special-case handlers
(Reference list. To be expanded.)

## §4 Sign extension (post-MVP)

`i32.extend8_s`, `i32.extend16_s`, `i64.extend8_s`, `i64.extend16_s`, `i64.extend32_s` lower as `(x << N) >> N` using two EXTERN calls per instruction:

| WASM op | shift count | LeftShift signature | RightShift signature |
| --- | --- | --- | --- |
| `i32.extend8_s` | 24 | `SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32` | `SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32` |
| `i32.extend16_s` | 16 | (same) | (same) |
| `i64.extend8_s` | 56 | `SystemInt64.__op_LeftShift__SystemInt64_SystemInt32__SystemInt64` | `SystemInt64.__op_RightShift__SystemInt64_SystemInt32__SystemInt64` |
| `i64.extend16_s` | 48 | (same) | (same) |
| `i64.extend32_s` | 32 | (same) | (same) |

Both i64 shift signatures take `SystemInt32` for the RHS — this matches the existing entries in `lower_numeric.zig`.

The shift count is materialised through a shared `__c_i32_<N>` data field
(declared once in `emitCommonData`); both the i32 and i64 shift EXTERNs pull
the count from the same Int32 constant pool.

The lowering is intentionally a dedicated helper (`Translator.emitSignExtend`),
not a `lower_numeric.zig` table entry: the table is for single-EXTERN ops, and
sign extension is a synthesised two-EXTERN sequence. The dispatch in `emitOne`
intercepts the five opcodes ahead of `numeric.lookup` to keep the table
single-purpose.

Worked example (i32.extend8_s on 0x80):
- Input stack top is `0x00000080` (treated as Int32).
- `LeftShift 24` produces `0x80000000`.
- Arithmetic `RightShift 24` produces `0xFFFFFF80`, which is the sign-extended value.

## §5 Saturating truncation (post-MVP)

The eight non-trapping float-to-int opcodes (the `nontrapping-fptoint`
proposal) lower through two shared synthesised helper subroutines — one per
output bit width — that implement the WASM saturation semantics
(NaN → 0; below low clamp → MIN/0; above high clamp → MAX/UINT_MAX; else
plain truncation).

| WASM op                   | input | output         | low clamp constant   | high clamp constant   | low result constant | high result constant |
| ------------------------- | ----- | -------------- | -------------------- | --------------------- | ------------------- | -------------------- |
| `i32.trunc_sat_f32_s`     | f32   | i32 (signed)   | `__c_f64_int32_min`  | `__c_f64_int32_max`   | `__c_i32_int_min`   | `__c_i32_int_max`    |
| `i32.trunc_sat_f32_u`     | f32   | i32 (unsigned) | `__c_f64_zero`       | `__c_f64_uint32_max`  | `__c_i32_0`         | `__c_i32_neg1`       |
| `i32.trunc_sat_f64_s`     | f64   | i32 (signed)   | `__c_f64_int32_min`  | `__c_f64_int32_max`   | `__c_i32_int_min`   | `__c_i32_int_max`    |
| `i32.trunc_sat_f64_u`     | f64   | i32 (unsigned) | `__c_f64_zero`       | `__c_f64_uint32_max`  | `__c_i32_0`         | `__c_i32_neg1`       |
| `i64.trunc_sat_f32_s`     | f32   | i64 (signed)   | `__c_f64_int64_min`  | `__c_f64_int64_max`   | `__c_i64_int_min`   | `__c_i64_int_max`    |
| `i64.trunc_sat_f32_u`     | f32   | i64 (unsigned) | `__c_f64_zero`       | `__c_f64_uint64_max`  | `__c_i64_zero`      | `__c_i64_neg1`       |
| `i64.trunc_sat_f64_s`     | f64   | i64 (signed)   | `__c_f64_int64_min`  | `__c_f64_int64_max`   | `__c_i64_int_min`   | `__c_i64_int_max`    |
| `i64.trunc_sat_f64_u`     | f64   | i64 (unsigned) | `__c_f64_zero`       | `__c_f64_uint64_max`  | `__c_i64_zero`      | `__c_i64_neg1`       |

Note on the unsigned high-result constants: WASM saturates `>= 2^N` to
`UINT_MAX` (= `2^N - 1`), but Udon's `SystemInt32` / `SystemInt64` slots
hold the result with two's-complement bit patterns, so `UINT32_MAX` lowers
to `__c_i32_neg1` (= `-1`) and `UINT64_MAX` to `__c_i64_neg1` (= `-1L`).
A consumer that reads the slot back as an unsigned value through
`BitConverter` recovers the WASM-visible bit pattern.

### Two-helper architecture

There is exactly one helper body per output bit width:

- `__rt_trunc_sat_to_i32__` — input in `_ts_in_f64`, low/high clamps in
  `_ts_lo_f64` / `_ts_hi_f64`, low/high result candidates in
  `_ts_lo_out_i32` / `_ts_hi_out_i32`, output written into `_ts_out_i32`.
- `__rt_trunc_sat_to_i64__` — analogous, with `_ts_lo_out_i64` /
  `_ts_hi_out_i64` / `_ts_out_i64`.

f32 inputs are promoted to `f64` at every call site (using the
`f64.promote_f32` extern signature
`SystemConvert.__ToDouble__SystemSingle__SystemDouble`, the same entry the
table in `lower_numeric.zig` already uses for `.f64_promote_f32`) so both
helpers consume a single `SystemDouble` input slot regardless of the
opcode's WASM-side input width. This lets the eight opcodes share two
helper bodies instead of four.

### Helper body structure

Each helper body executes four branches in sequence and JUMPs through
`JUMP_INDIRECT` when done:

1. **NaN guard.** `_ts_cmp := (_ts_in_f64 != _ts_in_f64)` via
   `SystemDouble.__op_Inequality__SystemDouble_SystemDouble__SystemBoolean`.
   If true, write `0` into `_ts_out_<i32|i64>` and JUMP to the done label.
2. **Low clamp.** `_ts_cmp := (_ts_in_f64 <= _ts_lo_f64)` via
   `SystemDouble.__op_LessThanOrEqual__SystemDouble_SystemDouble__SystemBoolean`.
   If true, COPY the staged low-result slot into `_ts_out_*` and JUMP done.
3. **High clamp.** `_ts_cmp := (_ts_in_f64 >= _ts_hi_f64)` via
   `SystemDouble.__op_GreaterThanOrEqual__SystemDouble_SystemDouble__SystemBoolean`.
   If true, COPY the staged high-result slot into `_ts_out_*` and JUMP done.
4. **In range.** `_ts_out_* := SystemConvert.ToInt{32,64}(_ts_in_f64)` via
   `SystemConvert.__ToInt32__SystemDouble__SystemInt32` (or the
   `__ToInt64__` variant). Reaching this branch implies the value lies
   in `(lo, hi)` so the checked `SystemConvert` cannot overflow.

The done label is followed by `JUMP_INDIRECT, __ret_addr_trunc_sat_<i32|i64>__`
which returns control to the caller's per-call-site return label.

### Call/return ABI (RAC reuse)

The two helpers reuse the existing return-address-constant machinery
described in `docs/spec_call_return_conversion.md` §3 / §5:

- A pair of shared Udon `SystemUInt32` slots —
  `__ret_addr_trunc_sat_i32__` and `__ret_addr_trunc_sat_i64__` — hold
  the helper's return address, one per output bit width.
- Every call site mints a fresh per-site `__rt_trunc_sat_rac_<i32|i64>_<K>__`
  RAC (registered with `Translator.rac_sites` so Pass A backfills its
  literal with the address of the matching `__rt_trunc_sat_ret_<i32|i64>_<K>__`
  return label), COPYies the RAC into the bit-width-shared `__ret_addr_*`
  slot, then JUMPs to `__rt_trunc_sat_to_<i32|i64>__`.
- The helper's terminal `JUMP_INDIRECT` reads `__ret_addr_trunc_sat_*__`
  and lands on the call site's return label, where the call site COPYs
  `_ts_out_<i32|i64>` into the WASM-visible stack slot and continues.

The two helper bodies are emitted exactly once each per translation unit,
right after `emitDefinedFunctions`, gated by
`Translator.trunc_sat_helper_needed_i32` / `_i64` flags that the call-site
lowering sets the first time it dispatches an opcode of that bit width.
The helpers are never reached as fall-through — every entry is via JUMP.

### Constants and scratch slots

The trunc_sat data declarations live in a dedicated `ensureTruncSatData`
helper (called lazily on the first `emitTruncSat` to keep
trunc_sat-free modules from paying the `_onEnable` synthesis cost):

- f64 clamps: `__c_f64_zero`, `__c_f64_int32_min`, `__c_f64_int32_max`,
  `__c_f64_uint32_max`, `__c_f64_int64_min`, `__c_f64_int64_max`,
  `__c_f64_uint64_max`. Each is registered through the same hi/lo
  bit-pattern synthesis pipeline `emitF64Const` uses (Udon spec §4.7
  forbids non-null `SystemDouble` literals, so the values are
  materialised in `_onEnable` via `BitConverter.GetBytes` /
  `BitConverter.ToDouble`).
- i64 result constants: `__c_i64_zero`, `__c_i64_neg1`,
  `__c_i64_int_min`, `__c_i64_int_max`. Same Int64-via-BitConverter
  pipeline as `emitI64Const`.
- i32 result constants: `__c_i32_int_min`, `__c_i32_int_max`. Plus the
  pre-existing `__c_i32_0` / `__c_i32_neg1` declared by
  `emitMemoryData`.
- Scratch slots: `_ts_in_f64`, `_ts_lo_f64`, `_ts_hi_f64`,
  `_ts_lo_out_i32`, `_ts_hi_out_i32`, `_ts_lo_out_i64`,
  `_ts_hi_out_i64`, `_ts_out_i32`, `_ts_out_i64`, and the shared
  `_ts_cmp` `SystemBoolean` slot.
- RA slots: `__ret_addr_trunc_sat_i32__` and `__ret_addr_trunc_sat_i64__`
  (`SystemUInt32`).

### Producer-side example

A worked WAT module exercising both helpers lives at
`examples/post-mvp/nontrapping-fptoint/example.wat`. Build it with
`wat2wasm --enable-saturating-float-to-int`.

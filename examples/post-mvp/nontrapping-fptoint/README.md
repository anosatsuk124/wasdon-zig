# Post-MVP example: nontrapping float-to-int (saturating truncation)

This example demonstrates the post-MVP `nontrapping-fptoint` proposal end-to-end:

- `$sat_i32_f32` uses `i32.trunc_sat_f32_s` to saturate-truncate an `f32` to a signed `i32`.
- `$sat_u64_f64` uses `i64.trunc_sat_f64_u` to saturate-truncate an `f64` to an unsigned `i64`.

All eight `*.trunc_sat_*` opcodes lower through one of two shared Udon helper
subroutines (one per output bit width: `__rt_trunc_sat_to_i32__` /
`__rt_trunc_sat_to_i64__`). Each helper implements the WASM saturation
semantics: `NaN → 0`, values below the low clamp → `INT_MIN` (or `0` for
unsigned), values above the high clamp → `INT_MAX` (or `UINT_MAX`), otherwise
plain `SystemConvert.__ToInt{32,64}__SystemDouble__*` truncation.

f32 inputs are promoted to `f64` at every call site so both helpers operate
on a `SystemDouble` input slot, and the helpers are reached via the existing
RAC + `JUMP_INDIRECT` machinery
(`docs/spec_call_return_conversion.md`). See
`docs/spec_numeric_instruction_lowering.md` §5 for the full lowering scheme.

## Build

```sh
wat2wasm --enable-saturating-float-to-int example.wat -o example.wasm
```

(The `--enable-saturating-float-to-int` flag is enabled by default in modern
wabt; it is passed here for explicitness so the producer intent is clear when
reading the command line.)

## Translate

```sh
zig build run -- examples/post-mvp/nontrapping-fptoint/example.wasm
```

The emitted Udon Assembly should contain:

- `__rt_trunc_sat_to_i32__:` and `__rt_trunc_sat_to_i64__:` helper labels (each
  appearing exactly once);
- `SystemDouble.__op_Inequality__` / `__op_LessThanOrEqual__` /
  `__op_GreaterThanOrEqual__` EXTERN calls inside each helper body;
- `SystemConvert.__ToInt32__SystemDouble__SystemInt32` and
  `SystemConvert.__ToInt64__SystemDouble__SystemInt64` for the in-range branch;
- one `SystemConvert.__ToDouble__SystemSingle__SystemDouble` per `*.trunc_sat_f32_*`
  call site (for the f32→f64 promotion);
- no `ANNOTATION __unsupported__` lines for any of the eight opcodes.

# Post-MVP example: sign extension

This example demonstrates the post-MVP sign-extension proposal end-to-end:

- `$sx_i8` uses `i32.extend8_s` to sign-extend the low byte of an `i32`.
- `$sx_i16_64` uses `i64.extend16_s` to sign-extend the low 16 bits of an `i64`.

Each opcode lowers as `(x << N) >> N` over the existing `__op_LeftShift__` /
`__op_RightShift__` EXTERNs on `SystemInt32` / `SystemInt64`. See
`docs/spec_numeric_instruction_lowering.md` §4.

## Build

```sh
wat2wasm --enable-sign-extension example.wat -o example.wasm
```

The `--enable-sign-extension` flag is enabled by default in modern wabt; it is
passed here for explicitness so the producer intent is clear when reading the
command line.

## Translate

```sh
zig build run -- examples/post-mvp/sign-extension/example.wasm
```

The emitted Udon Assembly should contain two LeftShift / RightShift EXTERN
pairs (one Int32 pair for `sx_i8`, one Int64 pair for `sx_i16_64`) and no
`ANNOTATION __unsupported__` lines.

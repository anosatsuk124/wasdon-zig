# Post-MVP example: memory.fill

This example exercises the WASM bulk-memory `memory.fill` instruction
end-to-end through the translator.

`$fill_64` writes 64 copies of the byte `0xCC` starting at `dst`.
WASM `memory.fill` consumes `(dst, val, n)` from the operand stack.
The translator lowers it to a forward byte-store loop that reuses the
shared `emitMemStoreByteAt` helper (so `val` is masked to the low 8
bits inside the helper). See `docs/spec_linear_memory.md`
§"memory.fill lowering" for the full lowering recipe and the per-call
label uniquing scheme.

## Build

```sh
wat2wasm --enable-bulk-memory example.wat -o example.wasm
```

The `--enable-bulk-memory` flag is enabled by default in modern wabt;
it is passed here for explicitness so the producer intent is clear from
the command line.

If `wat2wasm` is unavailable, the WAT alone is sufficient as a reference
fixture — translator-level tests live under
`src/translator/translate.zig` and synthesize the same `memory.fill`
sequence directly through the `Module` builder.

## Translate

```sh
zig build run -- examples/post-mvp/memory-fill/example.wasm
```

Expected markers in the emitted Udon Assembly (one `$fill_64` body):

- A `__memfill_loop_<id>__` label and a matching `__memfill_end_<id>__`
  exit label, both keyed by `block_counter`.
- An `i < n` guard via
  `SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean`
  emitted before any byte-store EXTERN, so a zero-length call short-
  circuits to the end label without entering the body.
- A byte-store RMW inside the loop ending with
  `SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid`.
- No `ANNOTATION __unsupported__` line for `memory.fill`.

The `_mf_*` scratch fields (`_mf_dst`, `_mf_val`, `_mf_n`, `_mf_i`,
`_mf_addr`, `_mf_cmp`) are declared once at the top of the data
section and reused across every `memory.fill` site in the program.

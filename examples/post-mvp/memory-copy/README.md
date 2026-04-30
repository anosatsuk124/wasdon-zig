# Post-MVP example: memory.copy

This example exercises the WASM bulk-memory `memory.copy` instruction
end-to-end through the translator.

`$copy` consumes `(dst, src, n)` from the operand stack and copies `n`
bytes from `src` to `dst`. The WASM spec guarantees overlap-safe
semantics: when `src` and `dst` ranges overlap, the result must match a
disjoint copy of the original source bytes. The translator implements
this by emitting a runtime direction check (`dst <= src` ⇒ ascending,
otherwise descending) followed by a byte-by-byte loop that reuses the
shared `emitMemLoadByteAt` / `emitMemStoreByteAt` helpers. See
`docs/spec_linear_memory.md` §"memory.copy lowering" for the lowering
recipe and the per-call label uniquing scheme.

## Build

```sh
wat2wasm --enable-bulk-memory example.wat -o example.wasm
```

The `--enable-bulk-memory` flag is enabled by default in modern wabt;
it is passed here for explicitness so the producer intent is clear from
the command line.

If `wat2wasm` is unavailable, the WAT alone is sufficient as a reference
fixture — translator-level tests live under
`src/translator/translate.zig` and synthesize the same `memory.copy`
sequence directly through the `Module` builder.

## Translate

```sh
zig build run -- examples/post-mvp/memory-copy/example.wasm
```

Expected markers in the emitted Udon Assembly (one `$copy` body):

- A `SystemInt32.__op_LessThanOrEqual__SystemInt32_SystemInt32__SystemBoolean`
  EXTERN that selects the copy direction.
- Two loop label families, both keyed by `block_counter`:
  `__memcopy_fwd_loop_<id>__` and `__memcopy_back_loop_<id>__`, plus a
  shared `__memcopy_end_<id>__` exit label.
- Inside each loop body: a byte-load (mask `0xFF` over a `SystemUInt32`
  word) and a byte-store RMW that ends with
  `SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid`.
- No `ANNOTATION __unsupported__` line for `memory.copy`.

The `_mc_*` scratch fields (`_mc_dst`, `_mc_src`, `_mc_n`, `_mc_i`,
`_mc_addr_src`, `_mc_addr_dst`, `_mc_byte`, `_mc_cmp`) are declared
once at the top of the data section and reused across every
`memory.copy` site in the program.

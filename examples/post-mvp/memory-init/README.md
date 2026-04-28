# Post-MVP example: memory.init

This example exercises the WASM bulk-memory `memory.init` instruction
end-to-end through the translator.

`$do_init` copies 4 bytes (`"ABCD"`) from passive data segment 0 into
linear memory at address 100, then performs an `i32.load` at the same
address (and drops the result) to keep the destination address live in
the produced bytecode.

`memory.init` consumes `(dst, src, n)` from the operand stack — `dst`
is the destination address in linear memory, `src` is the byte offset
*within* the segment, and `n` is the byte count. The translator lowers
it to a forward byte-copy loop sourced from `__G__data_seg_<idx>__bytes`
(the `SystemByteArray` materialised from the passive segment) and
sinking through the shared `emitMemStoreByteAt` helper. See
`docs/spec_linear_memory.md` §"memory.init lowering".

## Build

```sh
wat2wasm example.wat -o example.wasm
```

(In wabt 1.0.39 the bulk-memory proposal is on by default.)

## Verify

`wasm-objdump -h example.wasm` should list a `DataCount` section
between `Export` and `Code`:

```
     Type      count: 1
 Function     count: 1
   Memory     count: 1
   Export     count: 2
DataCount     count: 1
     Code     count: 1
     Data     count: 1
```

`wasm-objdump -d example.wasm` should disassemble the body to:

```
i32.const 100         ;; 41 e4 00
i32.const 0           ;; 41 00
i32.const 4           ;; 41 04
memory.init 0 0       ;; fc 08 00 00   (data_idx=0, reserved memidx=0)
i32.const 100         ;; 41 e4 00
i32.load 2 0          ;; 28 02 00
drop                  ;; 1a
end                   ;; 0b
```

`wasm-objdump -x example.wasm` should show
`segment[0] passive size=4` with payload `4142 4344` (`"ABCD"`).

## Translate

```sh
zig build run -- examples/post-mvp/memory-init/example.wasm
```

Expected markers in the emitted Udon Assembly (one `$do_init` body):

- `__G__data_seg_0__bytes` and `__G__data_seg_0__dropped` field
  declarations.
- A `__meminit_loop_<id>__` label and a matching
  `__meminit_end_<id>__` exit label, both keyed by `block_counter`.
- A `SystemByteArray.__Get__SystemInt32__SystemByte` (or equivalent)
  EXTERN inside the loop body that fetches the source byte from the
  segment.
- A byte-store RMW into linear memory ending with
  `SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid`.
- A `JUMP_IF_FALSE` against `__G__data_seg_0__dropped` so a dropped
  segment traps before any byte is read.
- No `ANNOTATION __unsupported__` line for `memory.init`.

The `_mi_*` scratch fields (`_mi_dst`, `_mi_src`, `_mi_n`, `_mi_i`,
`_mi_byte`) are declared once at the top of the data section and
reused across every `memory.init` site in the program.

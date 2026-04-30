# Post-MVP example: passive data segment (mode 0x01)

This example exists purely as a parser-level fixture for the bulk-memory
proposal's passive data segment encoding. The module declares one
linear memory and one passive data segment containing the bytes
`"Hello\0"` (6 bytes, including the trailing NUL). The exported
`_start` function has an empty body (a single `end` opcode).

There is no `memory.init` and no `data.drop`, so this example does NOT
exercise the `DataCount` section — wat2wasm only emits `DataCount` when
the code actually references a passive segment by index. Coverage for
`DataCount` lives in the sibling `memory-init/` and `data-drop/`
examples; the parser must accept *both* the `DataCount-present` and
`DataCount-absent` variants of a passive segment.

## Build

```sh
wat2wasm example.wat -o example.wasm
```

(In wabt 1.0.39 the bulk-memory and reference-types proposals are on by
default; pass `--disable-bulk-memory` to opt out.)

## Verify

`wasm-objdump -h example.wasm` should list these sections (note the
absence of `DataCount`):

```
     Type      count: 1
 Function     count: 1
   Memory     count: 1
   Export     count: 2
     Code     count: 1
     Data     count: 1
```

`wasm-objdump -x example.wasm` should show the segment as
`segment[0] passive size=6` with payload `4865 6c6c 6f00` (`"Hello\0"`).

## Translate

```sh
zig build run -- examples/post-mvp/bulk-memory-passive/example.wasm
```

Expected markers in the emitted Udon Assembly:

- A `__G__data_seg_0__bytes` field declaration (a `SystemByteArray`
  initialised with the 6 bytes of `"Hello\0"`).
- A companion `__G__data_seg_0__dropped: SystemBoolean` field
  initialised to `false`.
- No `ANNOTATION __unsupported__` line for the data segment.

See `docs/spec_linear_memory.md` §"Passive data segments" for the field
naming scheme and the byte-array materialisation contract.

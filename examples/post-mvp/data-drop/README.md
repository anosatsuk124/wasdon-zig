# Post-MVP example: data.drop

This example exercises the WASM bulk-memory `data.drop` instruction
end-to-end through the translator, paired with a `memory.init` so that
the dropped segment has been observably consumed first.

`$do_drop` copies 3 bytes (`"XYZ"`) from passive data segment 0 into
linear memory at offset 0, then drops the segment. After `data.drop`,
any subsequent `memory.init` referencing the same segment must trap.

`data.drop` takes a single `data_idx` immediate and (per WASM spec)
marks the segment as no longer accessible. The translator models this
by setting `__G__data_seg_<idx>__dropped = true`. See
`docs/spec_linear_memory.md` §"data.drop lowering".

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
i32.const 0           ;; 41 00
i32.const 0           ;; 41 00
i32.const 3           ;; 41 03
memory.init 0 0       ;; fc 08 00 00   (data_idx=0, reserved memidx=0)
data.drop 0           ;; fc 09 00      (data_idx=0)
end                   ;; 0b
```

`wasm-objdump -x example.wasm` should show
`segment[0] passive size=3` with payload `5859 5a` (`"XYZ"`).

## Translate

```sh
zig build run -- examples/post-mvp/data-drop/example.wasm
```

Expected markers in the emitted Udon Assembly (one `$do_drop` body):

- `__G__data_seg_0__bytes` and `__G__data_seg_0__dropped` field
  declarations (the latter initialised to `false` at module load).
- The `memory.init` lowering markers documented under
  `examples/post-mvp/memory-init/README.md`.
- A single Udon assignment that pushes `true` into
  `__G__data_seg_0__dropped` (the `data.drop` lowering — one COPY into
  a constant-`true` field).
- No `ANNOTATION __unsupported__` line for `data.drop`.

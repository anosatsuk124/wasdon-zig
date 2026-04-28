# Post-MVP example: mutable globals

This example demonstrates the post-MVP `mutable-globals` proposal end-to-end:

- An imported mutable global `env.host_counter` (the host writes it; the WASM
  module reads it through `global.get`).
- A module-defined mutable global `$local` that the WASM module both reads and
  writes via `global.get` / `global.set`.
- A `__udon_meta` blob locating itself with the exported `(ptr, len)` pair,
  giving `$local` an explicit Udon variable name and binding `tick` to the
  `_update` event label.

## Build

```sh
wat2wasm --enable-mutable-globals example.wat -o example.wasm
```

The `--enable-mutable-globals` flag is enabled by default in modern wabt; it is
passed here for explicitness so the producer intent is clear when reading the
command line.

## Translate

```sh
zig build run -- examples/post-mvp/mutable-globals/example.wasm
```

The emitted Udon Assembly should contain `__G__host_counter: %SystemInt32`
and `__G__local: %SystemInt32` data declarations and a `_update`-labelled
entry corresponding to `tick`. No `ANNOTATION __unsupported__` lines should
appear in the body.

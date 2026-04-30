# Variables Conversion strategy

## Problem

### Global vs. Local

In Udon Assembly, there's no difference between a global variable and a local one. But in WebAssembly, there is.

There's a need to convert local variables to global ones with a way to keep them distinguishable from the original global ones.

### Avoidance of name collision

In Udon Assembly, there are some possible name collisions of reserved variables.

## Solution

The solution is to generate the name of all variables with the rules below:

### Rules (in order)

- If the variable is a local one, prepend `{function_name}_L{local_index}__` to its name.

  - `function_name` is the name of the function in which the variable should be called.
  - `local_index` is the index of the variable in the function.

- If the variable is a global one, prepend `G__` to its name.

- Prepend `__` to the name of all variables.

## Mutability

WASM globals carry a `mut` flag (`mut = 0x00` immutable, `mut = 0x01` mutable
— the post-MVP "mutable-globals" proposal lifts the MVP restriction on
imported mutable globals, but the bit itself has always been part of the
binary format).

Udon has no `const` concept for data-section fields: every entry in the
`.data_start ... .data_end` section is a writable slot. The translator
therefore lowers **both** mutable and immutable WASM globals to mutable
Udon data fields using exactly the naming scheme above. The `mut` flag does
not change emission.

The flag is round-tripped through the parser (see
`src/wasm/types.zig`'s `decodeGlobalType` and the `parseImportSection`
test in `src/wasm/module.zig`) and is available to the optional
`__udon_meta` documentation field, but it does not affect translator
behavior. Imported mutable globals from the host are reached as ordinary
Udon fields — host-side writes via Udon's `SetVariable` mechanism are
visible to the WASM side through normal `global.get`.

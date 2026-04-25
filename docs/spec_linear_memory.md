# Linear Memory Conversion Strategy

## Problem

WebAssembly's linear memory imposes three properties that Udon cannot satisfy directly:

1. **Byte addressing with type punning.** A byte-level store followed by an i32 load at the same address must observe the stored bytes. Narrow loads (`i32.load8_u`), unaligned loads, and reinterpretation of floats as integers (`f32.reinterpret_i32`) all require a byte-level model.
2. **Fixed-length Udon arrays.** Udon exposes `.NET` array types but does not provide an `Array.Resize` EXTERN, and the documented node set does not include in-place buffer growth. WASM `memory.grow`, however, must be able to extend memory at runtime.
3. **No raw byte memory type guaranteed on the Udon whitelist.** `SystemByteArray` is not documented as available, and even if it were, every multi-byte load/store would need three to eight EXTERN calls (bit shifts, masks, and per-byte access all go through EXTERN nodes on Udon). The translator targets Rust/C compiler output and hand-written WAT, so multi-byte access is the common case.

## Solution Overview

Linear memory is modeled as a **two-level array**:

- **Outer**: a `SystemObjectArray` of length `max_pages`. Each slot either holds `null` (uncommitted) or a reference to an inner chunk.
- **Inner (chunk)**: a `SystemUInt32Array` of length `16384` (= 65536 bytes = one WASM page), storing four bytes per slot in little-endian order.

A scalar `__G__memory_size_pages` tracks how many pages are currently committed. `memory.grow` allocates new inner chunks and writes them into the outer array, so memory can grow at runtime up to `max_pages` without copying existing data. Byte-level semantics are preserved by emitting shift/mask sequences for narrow, unaligned, or type-punned access.

## Memory Layout

### Data section

Using the `__G__` prefix rule from `spec_variable_conversion.md`:

```
.data_start
  __G__memory:            %SystemObjectArray, null
  __G__memory_size_pages: %SystemInt32, 0
  __G__memory_max_pages:  %SystemInt32, <max_pages>
.data_end
```

The translator may additionally emit the scratch variables below in the data section (Udon has no locals). Names are suggestions; the translator is free to mangle them as long as they do not collide with user fields.

```
  _mem_page_idx:      %SystemInt32, 0
  _mem_byte_in_page:  %SystemInt32, 0
  _mem_word_in_page:  %SystemInt32, 0
  _mem_sub:           %SystemInt32, 0
  _mem_chunk:         %SystemUInt32Array, null
  _mem_u32:           %SystemUInt32, 0
```

### EXTERN signatures used

```
SystemObjectArray.__ctor__SystemInt32__SystemObjectArray
SystemObjectArray.__GetValue__SystemInt32__SystemObject
SystemObjectArray.__SetValue__SystemObject_SystemInt32__SystemVoid

SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array
SystemUInt32Array.__Get__SystemInt32__SystemUInt32
SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid
```

Note: Udon exposes typed-array element access only through the indexer-style `__Get__` / `__Set__` nodes on `SystemUInt32Array`. The inherited `SystemArray.GetValue`/`SetValue` nodes exist but are typed in terms of `SystemObject`; the typed `SystemUInt32` overloads are *not* exposed, so word loads/stores in linear memory must use the indexer form.

Arithmetic, shift, mask, and comparison operations on `SystemInt32` / `SystemUInt32` use the usual operator-style EXTERN nodes. Note that `SystemUInt32` does not expose `__op_Bitwise*__` or `__op_OnesComplement__` — the translator uses `__op_LogicalAnd__` / `__op_LogicalOr__` / `__op_LogicalXor__` instead and synthesizes `~x` as `x XOR 0xFFFFFFFF` (`docs/udon_specs.md` §7).

Note: a `SystemObjectArray.__GetValue__` result is typed as `SystemObject`. Before invoking inner EXTERNs it is assigned to a `SystemUInt32Array`-typed variable (`_mem_chunk` above); Udon accepts this object-to-concrete-array assignment.

## Address Decomposition

Given a WASM byte address `addr` (`SystemInt32`) and an access width in bytes:

```
page_idx      = addr >> 16
byte_in_page  = addr & 0xFFFF
word_in_page  = byte_in_page >> 2
sub           = byte_in_page & 3
```

An access is **within-chunk** iff `byte_in_page + width <= 65536`; otherwise it straddles two consecutive pages and both `outer[page_idx]` and `outer[page_idx + 1]` must be fetched. Translators may elide the straddle check when the WASM source guarantees natural alignment and the page size boundary is not reached.

The base access pattern to fetch one 32-bit word:

```uasm
    # _mem_page_idx, _mem_word_in_page must be precomputed
    PUSH, __G__memory
    PUSH, _mem_page_idx
    PUSH, _mem_chunk
    EXTERN, "SystemObjectArray.__GetValue__SystemInt32__SystemObject"
    PUSH, _mem_chunk
    PUSH, _mem_word_in_page
    PUSH, _mem_u32
    EXTERN, "SystemUInt32Array.__Get__SystemInt32__SystemUInt32"
```

A symmetrical pattern using the typed-array indexer setter `SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid` is used to write a word. Note that `Set` takes the arguments in `(index, value)` order — opposite of the inherited `Array.SetValue(value, index)`. Udon does not expose a typed-`UInt32` overload of `SetValue` on `SystemUInt32Array`, so the indexer setter is mandatory for word writes.

## Load/Store Expansion Rules

All multi-byte accesses are little-endian (WASM is LE by specification). Every access is preceded by a bounds check of the form `addr + width <= size_pages * 65536`; the check is emitted as a `JUMP_IF_FALSE` branch to a trap label.

| WASM instruction | Expansion outline | EXTERN count (typical) |
|---|---|---|
| `i32.load` aligned, within-chunk | outer GetValue + inner GetValue | 2 |
| `i32.load` unaligned, within-chunk | 2 inner GetValue + shift + or | 5 |
| `i32.load` unaligned, straddling pages | 2 outer + 2 inner + shift + or | 6 |
| `i32.load8_u` | outer GetValue + inner GetValue + right-shift + and 0xFF | 4 |
| `i32.load8_s` | `i32.load8_u` followed by sign extension (shift left then right) | 6 |
| `i32.load16_u` / `_s` | same as `load8` but with 16-bit shift/mask; straddles require extra fetches | 4–7 |
| `i64.load` aligned, within-chunk | 1 outer + 2 inner + combine (shift + or) | 4 |
| `i64.load` straddling pages | 2 outer + 2 inner + combine | 5 |
| `f32.load` / `f64.load` | integer load followed by bit-reinterpret (`SystemBitConverter.__ToSingle__...` or equivalent) | integer load + 2 |
| `i32.store` aligned | outer GetValue + inner SetValue | 2 |
| `i32.store` unaligned | 2 read-modify-write (straddle: 2 outer GetValue) | 10–12 |
| `i32.store8` | outer GetValue + inner GetValue + mask + shift + or + inner SetValue (RMW) | 8 |
| `i32.store16` | RMW with 16-bit window | 8 |
| `i64.store` aligned | outer GetValue + 2 inner SetValue | 3 |
| `f32.store` / `f64.store` | bit-reinterpret to integer then integer store | 2 + store |
| `memory.copy` | for word-aligned src/dst within a chunk, inner `GetValue`/`SetValue` loop; otherwise byte RMW loop | implementation-defined |
| `memory.fill` | word-at-a-time loop, falling back to RMW at unaligned ends | implementation-defined |

> **Implementation status note for `i32.load16_u` / `i32.load16_s`.** The
> current lowering reuses the byte-access preamble (single outer + single
> inner fetch) and shifts/masks the 16-bit window inside that one chunk
> word. This assumes `(addr & 3) ∈ {0, 2}` — i.e. the half-word is
> 2-byte aligned and does not straddle the word boundary. Rust on
> `wasm32v1-none` and Zig with default alignment always emit half-word
> accesses against 2-byte-aligned pointers, so this assumption holds for
> every example in `examples/`. A producer that issues a misaligned
> half-word load (e.g. `addr & 3 == 3`) will silently read only the
> high byte; the cross-word fallback is not yet implemented. Without
> this lowering, `i32.load16_u` falls through to a `__unsupported__`
> sentinel that pushes nothing onto the WASM stack — the resulting
> assembly imbalances the stack and Udon halts the UdonBehaviour at load
> time with no exception message (the only log line is "VM execution
> errored, halted"). This was the root cause of `wasm-bench-alloc-rs`
> halting before `_onEnable` could fire — Rust `alloc::raw_vec` reads a
> 2-byte u16 cap field via `i32.load16_u`.

### Example 1 — `i32.load` aligned, within-chunk

```uasm
    # effective address is in _addr (SystemInt32)
    # precompute page_idx, word_in_page
    PUSH, _addr
    PUSH, _const_16
    PUSH, _mem_page_idx
    EXTERN, "SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32"

    PUSH, _addr
    PUSH, _const_0xFFFF
    PUSH, _mem_byte_in_page
    EXTERN, "SystemInt32.__op_BitwiseAnd__SystemInt32_SystemInt32__SystemInt32"

    PUSH, _mem_byte_in_page
    PUSH, _const_2
    PUSH, _mem_word_in_page
    EXTERN, "SystemInt32.__op_RightShift__SystemInt32_SystemInt32__SystemInt32"

    # outer[page_idx] -> _mem_chunk
    PUSH, __G__memory
    PUSH, _mem_page_idx
    PUSH, _mem_chunk
    EXTERN, "SystemObjectArray.__GetValue__SystemInt32__SystemObject"

    # chunk[word_in_page] -> _result_u32
    PUSH, _mem_chunk
    PUSH, _mem_word_in_page
    PUSH, _result_u32
    EXTERN, "SystemUInt32Array.__Get__SystemInt32__SystemUInt32"
```

### Example 2 — `i32.load8_u`

```uasm
    # after page_idx / word_in_page / sub have been computed
    PUSH, __G__memory
    PUSH, _mem_page_idx
    PUSH, _mem_chunk
    EXTERN, "SystemObjectArray.__GetValue__SystemInt32__SystemObject"

    PUSH, _mem_chunk
    PUSH, _mem_word_in_page
    PUSH, _mem_u32
    EXTERN, "SystemUInt32Array.__Get__SystemInt32__SystemUInt32"

    # shift = sub * 8
    PUSH, _mem_sub
    PUSH, _const_3
    PUSH, _mem_shift
    EXTERN, "SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32"

    PUSH, _mem_u32
    PUSH, _mem_shift
    PUSH, _mem_u32_shifted
    EXTERN, "SystemUInt32.__op_RightShift__SystemUInt32_SystemInt32__SystemUInt32"

    PUSH, _mem_u32_shifted
    PUSH, _const_0xFF_u32
    PUSH, _result_byte
    EXTERN, "SystemUInt32.__op_BitwiseAnd__SystemUInt32_SystemUInt32__SystemUInt32"
```

### Example 3 — `i32.store8` (read-modify-write)

```uasm
    # Fetch target word
    PUSH, __G__memory
    PUSH, _mem_page_idx
    PUSH, _mem_chunk
    EXTERN, "SystemObjectArray.__GetValue__SystemInt32__SystemObject"

    PUSH, _mem_chunk
    PUSH, _mem_word_in_page
    PUSH, _mem_u32
    EXTERN, "SystemUInt32Array.__Get__SystemInt32__SystemUInt32"

    # Build mask ~(0xFF << shift) and AND with word
    PUSH, _mem_sub
    PUSH, _const_3
    PUSH, _mem_shift
    EXTERN, "SystemInt32.__op_LeftShift__SystemInt32_SystemInt32__SystemInt32"

    PUSH, _const_0xFF_u32
    PUSH, _mem_shift
    PUSH, _mem_mask_lo
    EXTERN, "SystemUInt32.__op_LeftShift__SystemUInt32_SystemInt32__SystemUInt32"

    PUSH, _mem_mask_lo
    PUSH, _mem_mask_inv
    EXTERN, "SystemUInt32.__op_OnesComplement__SystemUInt32__SystemUInt32"

    PUSH, _mem_u32
    PUSH, _mem_mask_inv
    PUSH, _mem_u32_cleared
    EXTERN, "SystemUInt32.__op_BitwiseAnd__SystemUInt32_SystemUInt32__SystemUInt32"

    # Shift new byte into place and OR
    PUSH, _new_byte
    PUSH, _mem_shift
    PUSH, _mem_byte_shifted
    EXTERN, "SystemUInt32.__op_LeftShift__SystemUInt32_SystemInt32__SystemUInt32"

    PUSH, _mem_u32_cleared
    PUSH, _mem_byte_shifted
    PUSH, _mem_u32_new
    EXTERN, "SystemUInt32.__op_BitwiseOr__SystemUInt32_SystemUInt32__SystemUInt32"

    # Write back
    PUSH, _mem_chunk
    PUSH, _mem_word_in_page
    PUSH, _mem_u32_new
    EXTERN, "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid"
```

### Example 4 — `i64.load` aligned, within-chunk

```uasm
    # Fetch low and high words from same chunk
    PUSH, __G__memory
    PUSH, _mem_page_idx
    PUSH, _mem_chunk
    EXTERN, "SystemObjectArray.__GetValue__SystemInt32__SystemObject"

    PUSH, _mem_chunk
    PUSH, _mem_word_in_page
    PUSH, _mem_u32_lo
    EXTERN, "SystemUInt32Array.__Get__SystemInt32__SystemUInt32"

    PUSH, _mem_word_in_page
    PUSH, _const_1
    PUSH, _mem_word_hi_idx
    EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"

    PUSH, _mem_chunk
    PUSH, _mem_word_hi_idx
    PUSH, _mem_u32_hi
    EXTERN, "SystemUInt32Array.__Get__SystemInt32__SystemUInt32"

    # Combine into i64: (u64)hi << 32 | (u64)lo
    # Cast to ulong and shift/or via SystemUInt64.* EXTERNs
    ...
```

Translators that can prove a straddle is impossible (for example, because the address is a compile-time constant) are free to skip the straddle branch.

## `memory.size` and `memory.grow`

### `memory.size`

Push `__G__memory_size_pages`.

### `memory.grow delta`

```
current = __G__memory_size_pages
new     = current + delta
if new > __G__memory_max_pages:
    push -1
else:
    for i in current .. new - 1:
        chunk = new SystemUInt32Array(16384)     # zero-initialized
        __G__memory[i] = chunk
    push current
    __G__memory_size_pages = new
```

Growth cost: for `k` new pages, roughly `2k + O(1)` EXTERN calls (one constructor + one outer SetValue per page). Existing memory is never copied. The outer array is allocated once at `_onEnable` with length `max_pages`, so growth never reallocates the outer structure.

Chunks returned by the constructor are zero-initialized, matching WASM's requirement that freshly grown memory contains zeros.

## Initialization

`_onEnable` (or, if the translator emits a dedicated `_initMemory` label, from the top of the first event entry) performs these steps:

1. `__G__memory = new SystemObjectArray(max_pages)`
2. `__G__memory_size_pages = initial_pages`
3. For `i = 0 .. initial_pages - 1`: allocate a `SystemUInt32Array(16384)` chunk and store it in `__G__memory[i]`.
4. Apply WASM data segments (below).

This confirms the initialization model that `spec_call_return_conversion.md` §8.2 / §14 flags as an open issue: memory and element segments are set up once at `_onEnable` and are not re-initialized later.

### Data segments

At translation time each WASM data segment is converted to a sequence of writes grouped by `page_idx`:

- For each group, emit a single `SystemObjectArray.__GetValue__` to fetch the target chunk into `_mem_chunk`, then emit contiguous `SystemUInt32Array.__Set__` calls for every aligned word in that chunk.
- For unaligned prefixes, suffixes, or byte-granular data, emit RMW sequences (one `SystemUInt32Array.__GetValue__` followed by mask/or/shift and a `SystemUInt32Array.__Set__`).
- Consecutive constant zeros may be elided because chunks are zero-initialized.

Large segments expand the code section significantly. A future revision may add a compression option (for example, run-length encoding of repeated bytes), but the initial implementation performs the straightforward expansion.

## Sizing Resolution

`initial_pages` and `max_pages` are determined as follows, in order:

1. If `__udon_meta.options.memory.{initialPages, maxPages}` is present, use those values.
2. Otherwise, use the `initial` and `max` of the WASM module's memory declaration.
3. If the WASM module declares no `max`:
   - `options.strict = true` → raise a translation error.
   - Otherwise → emit a warning and use a default `max = 256` (16 MiB).
4. `initialPages > maxPages` is a translation error.

`memory.grow` always refuses growth beyond `maxPages` (returns `-1`). The outer array is sized for `maxPages` at `_onEnable` and is not resized afterwards.

## `__udon_meta` Options

See `spec_udonmeta_conversion.md` for the full schema. The relevant subtree is:

```json
"options": {
  "memory": {
    "initialPages": 1,
    "maxPages": 256,
    "udonName": "_memory"
  }
}
```

- All fields are optional; omitted fields fall back to the resolution rules above.
- `udonName` overrides the outer array's Udon variable name (default: `__G__memory`). The scalar names `__G__memory_size_pages` and `__G__memory_max_pages` follow the same prefix rule and are renamed consistently.

## Chunk Cache (recommended optimization)

Because consecutive memory accesses frequently target the same `page_idx` (tight loops, struct field sequences), a one-slot chunk cache avoids redundant outer `GetValue` calls:

```
_mem_cache_chunk:  %SystemUInt32Array, null
_mem_cache_idx:    %SystemInt32, -1
```

Before fetching `outer[page_idx]`, the translator compares `page_idx` to `_mem_cache_idx`. On hit, `_mem_cache_chunk` is used directly. On miss, the cache is updated. The cache is invalidated whenever `memory.grow` runs (simply reset `_mem_cache_idx = -1`).

This optimization is encouraged but not required. Translators that do not emit the cache still produce correct code; the only cost is additional outer `GetValue` calls.

## Performance Notes

EXTERN invocations dominate Udon runtime cost. Rough EXTERN counts for a synthetic 1000-instruction workload (40 % aligned `i32.load/store`, 15 % `i32.load8_u`, 5 % aligned `i64.load`, 5 % narrow store, 35 % non-memory):

| Backing strategy | Total EXTERNs |
|---|---|
| `SystemByteArray` (reference only, rejected) | ~5800 |
| Single-level `SystemUInt32Array` (no runtime grow) | ~1750 |
| **Two-level chunked (this spec)** | **~3200** |
| Two-level chunked with chunk cache (warm hits) | ~2100 |

Hand-written WAT that respects natural alignment has the same characteristics; unaligned access doubles its word-fetch count and, if it straddles a page boundary, pulls in a second outer `GetValue`.

## Example — End-to-End

A module that grows memory by one page and writes/reads an i32 at address `0x10000` (the first byte of the newly grown page):

```uasm
.data_start
  __G__memory:            %SystemObjectArray, null
  __G__memory_size_pages: %SystemInt32, 0
  __G__memory_max_pages:  %SystemInt32, 16

  _const_0:               %SystemInt32, 0
  _const_1:               %SystemInt32, 1
  _const_16:              %SystemInt32, 16
  _const_65536:           %SystemInt32, 65536
  _const_chunk_size:      %SystemInt32, 16384
  _const_max_pages:       %SystemInt32, 16

  _mem_chunk:             %SystemUInt32Array, null
  _value:                 %SystemUInt32, 42
  _loaded:                %SystemUInt32, 0
  _grow_old_size:         %SystemInt32, 0
.data_end

.code_start
  .export _start
  _start:
    # --- _onEnable-style init ---
    PUSH, _const_max_pages
    PUSH, __G__memory
    EXTERN, "SystemObjectArray.__ctor__SystemInt32__SystemObjectArray"

    # initial_pages = 1: allocate chunk 0 and store in outer[0]
    PUSH, _const_chunk_size
    PUSH, _mem_chunk
    EXTERN, "SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array"
    PUSH, __G__memory
    PUSH, _mem_chunk
    PUSH, _const_0
    EXTERN, "SystemObjectArray.__SetValue__SystemObject_SystemInt32__SystemVoid"

    COPY, _const_1, __G__memory_size_pages

    # --- memory.grow 1 (adds page 1) ---
    # new chunk for outer[1]
    PUSH, _const_chunk_size
    PUSH, _mem_chunk
    EXTERN, "SystemUInt32Array.__ctor__SystemInt32__SystemUInt32Array"
    PUSH, __G__memory
    PUSH, _mem_chunk
    PUSH, _const_1
    EXTERN, "SystemObjectArray.__SetValue__SystemObject_SystemInt32__SystemVoid"
    COPY, __G__memory_size_pages, _grow_old_size
    # size_pages := size_pages + 1 (omitted for brevity)

    # --- i32.store 42 at addr 0x10000 (page_idx=1, word_in_page=0) ---
    PUSH, __G__memory
    PUSH, _const_1
    PUSH, _mem_chunk
    EXTERN, "SystemObjectArray.__GetValue__SystemInt32__SystemObject"
    PUSH, _mem_chunk
    PUSH, _const_0
    PUSH, _value
    EXTERN, "SystemUInt32Array.__Set__SystemInt32_SystemUInt32__SystemVoid"

    # --- i32.load at addr 0x10000 ---
    PUSH, __G__memory
    PUSH, _const_1
    PUSH, _mem_chunk
    EXTERN, "SystemObjectArray.__GetValue__SystemInt32__SystemObject"
    PUSH, _mem_chunk
    PUSH, _const_0
    PUSH, _loaded
    EXTERN, "SystemUInt32Array.__Get__SystemInt32__SystemUInt32"

    PUSH, _loaded
    EXTERN, "UnityEngineDebug.__Log__SystemObject__SystemVoid"
.code_end
```

## Open Questions and Constraints

- Shared memory and the threads proposal are not supported; loads and stores emit no fence/atomic semantics.
- The memory64 proposal is not supported; addresses are always `SystemInt32`.
- Atomic memory instructions (`memory.atomic.*`) are not supported.
- Straddling accesses (i64 or unaligned i32 that cross a page boundary) require two outer `GetValue` calls. The translator should emit a straddle-safe path unless alignment can be statically proven.
- `SystemBitConverter` EXTERN names used for float reinterpretation have not been enumerated here; they are documented alongside float support in a separate spec revision.

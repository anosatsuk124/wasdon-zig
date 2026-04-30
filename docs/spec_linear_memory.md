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
| `memory.copy` | runtime direction check + byte-by-byte loop reusing the byte load/store helpers (see §"memory.copy lowering" below) | 6 + 12·n |
| `memory.fill` | forward byte-store loop reusing the byte store helper (see §"memory.fill lowering" below) | 4 + 8·n |

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

## memory.copy lowering

`memory.copy` consumes `(dst, src, n)` from the operand stack and copies
`n` bytes from `src` to `dst`. The WASM bulk-memory specification
requires overlap-safe semantics: when the two ranges overlap, the
result must equal what a disjoint copy would produce. The translator
implements this with a **runtime direction check** rather than a static
disjointness proof:

- If `dst <= src`, copy ascending  (`for i in 0 .. n-1: mem[dst+i] = mem[src+i]`).
- Otherwise, copy descending      (`for i in n-1 .. 0:  mem[dst+i] = mem[src+i]`).

Both branches walk byte-by-byte through the existing byte load/store
helpers (`emitMemLoadByteAt` / `emitMemStoreByteAt`). The byte path is
the only safe choice today because it reuses the bounds-checked outer
`GetValue` and the RMW that already handle every alignment case; a
word-aligned bulk-copy fast path is left for a future optimisation
pass (see "Open Questions" below).

**Direction-test asymmetry.** The descending branch loops while
`i > -1` rather than `i >= 0`. Both forms are correct for signed
arithmetic, but `i > -1` future-proofs the lowering: if `n` is ever
treated as unsigned (e.g. for forward-compat with memory64-style
addresses), an `i >= 0` form would silently underflow at `i == 0` and
trip an OOB on the next iteration. The constant `__c_i32_neg1` is
already declared in the shared common-data block.

### Scratch slots

The lowering allocates eight `_mc_*` fields once in the data section
(via `emitMemoryData`) and reuses them across **every** `memory.copy`
site in the program. Reuse is sound because each call body fully
writes each scratch before reading it, and `memory.copy` cannot be
nested inside another `memory.copy` (each site is one straight-line
instruction sequence with no calls):

| Field | Type | Role |
|---|---|---|
| `_mc_dst` | `SystemInt32` | snapshot of the popped `dst` operand |
| `_mc_src` | `SystemInt32` | snapshot of the popped `src` operand |
| `_mc_n`   | `SystemInt32` | snapshot of the popped `n` operand |
| `_mc_i`   | `SystemInt32` | loop induction variable |
| `_mc_addr_src` | `SystemInt32` | `src + i` for the current iteration |
| `_mc_addr_dst` | `SystemInt32` | `dst + i` for the current iteration |
| `_mc_byte` | `SystemInt32` | byte value transferred between load and store |
| `_mc_cmp`  | `SystemBoolean` | direction-check and per-iteration loop guard result |

The byte helpers freely use the shared `_mem_*` scratch (`_mem_chunk`,
`_mem_u32`, `_mem_shift`, etc.) — those are clobbered on every call,
so the snapshots into `_mc_*` are necessary even though `dst` / `src`
/ `n` arrive on the WASM stack as already-named slots.

### Per-call labels via `block_counter`

The four labels emitted per call (`__memcopy_back_<id>__`,
`__memcopy_fwd_loop_<id>__`, `__memcopy_back_loop_<id>__`,
`__memcopy_end_<id>__`) are uniqued by `Translator.block_counter`,
which the call increments at the start. Two `memory.copy` ops in the
same function therefore produce two disjoint label families even
though they share the underlying scratch fields.

### Skeleton (per call)

```uasm
    # snapshot operands
    PUSH, <wasm_stack_dst>; PUSH, _mc_dst; COPY
    PUSH, <wasm_stack_src>; PUSH, _mc_src; COPY
    PUSH, <wasm_stack_n>;   PUSH, _mc_n;   COPY

    # direction: dst <= src ?
    PUSH, _mc_dst; PUSH, _mc_src; PUSH, _mc_cmp
    EXTERN, "SystemInt32.__op_LessThanOrEqual__SystemInt32_SystemInt32__SystemBoolean"
    PUSH, _mc_cmp
    JUMP_IF_FALSE, __memcopy_back_<id>__

    # forward branch: i = 0; while i < n { mem[dst+i] = mem[src+i]; i++ }
    PUSH, __c_i32_0; PUSH, _mc_i; COPY
__memcopy_fwd_loop_<id>__:
    PUSH, _mc_i; PUSH, _mc_n; PUSH, _mc_cmp
    EXTERN, "SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean"
    PUSH, _mc_cmp
    JUMP_IF_FALSE, __memcopy_end_<id>__
    # _mc_addr_src := src + i ; _mc_addr_dst := dst + i
    PUSH, _mc_src; PUSH, _mc_i; PUSH, _mc_addr_src
    EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
    PUSH, _mc_dst; PUSH, _mc_i; PUSH, _mc_addr_dst
    EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
    # mem[dst+i] := mem[src+i]   (via the shared byte helpers)
    # ... emitMemLoadByteAt(_mc_addr_src, _mc_byte) ...
    # ... emitMemStoreByteAt(_mc_addr_dst, _mc_byte) ...
    PUSH, _mc_i; PUSH, __c_i32_1; PUSH, _mc_i
    EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
    JUMP, __memcopy_fwd_loop_<id>__

__memcopy_back_<id>__:
    # backward branch: i = n - 1; while i > -1 { mem[dst+i] = mem[src+i]; i-- }
    PUSH, _mc_n; PUSH, __c_i32_1; PUSH, _mc_i
    EXTERN, "SystemInt32.__op_Subtraction__SystemInt32_SystemInt32__SystemInt32"
__memcopy_back_loop_<id>__:
    PUSH, _mc_i; PUSH, __c_i32_neg1; PUSH, _mc_cmp
    EXTERN, "SystemInt32.__op_GreaterThan__SystemInt32_SystemInt32__SystemBoolean"
    PUSH, _mc_cmp
    JUMP_IF_FALSE, __memcopy_end_<id>__
    # ... same per-iteration body as the forward branch ...
    PUSH, _mc_i; PUSH, __c_i32_1; PUSH, _mc_i
    EXTERN, "SystemInt32.__op_Subtraction__SystemInt32_SystemInt32__SystemInt32"
    JUMP, __memcopy_back_loop_<id>__

__memcopy_end_<id>__:
```

### Known limitations / future work

- **Pure byte loop, no bulk fast path.** Even when `dst`, `src`, and
  `n` are all word-aligned and lie within a single chunk, the current
  lowering still walks one byte at a time through the RMW byte-store
  helper. A future optimiser could detect alignment statically (or at
  runtime) and emit a `SystemUInt32Array.__Get__` / `__Set__` pair per
  word. Until then, large `memory.copy` calls are O(n) in the number
  of EXTERN calls — roughly twelve EXTERNs per byte copied — and will
  be visibly slower than a hand-rolled word loop.
- **No early-exit for `n == 0`.** The forward branch's first
  comparison short-circuits via `JUMP_IF_FALSE` to the end label, so
  a zero-length copy is correct but still pays the direction-check
  and one comparison.

## memory.fill lowering

`memory.fill` consumes `(dst, val, n)` from the operand stack and
writes the low 8 bits of `val` to `n` consecutive bytes starting at
`dst`. There is no overlap concern (only one range), so the
translator emits a single forward byte-store loop:

```
for i in 0 .. n-1: mem[dst+i] = val & 0xFF
```

The body reuses the shared `emitMemStoreByteAt` helper, which already
performs the `val & 0xFF` mask (via `SystemUInt32` AND) inside the
RMW. The full Int32 `val` is therefore forwarded as-is — the lowering
does not pre-mask. Just like `memory.copy`, the byte path is the only
safe choice today because it reuses the bounds-checked outer
`GetValue` and the RMW that already handle every alignment case; a
word-aligned bulk-fill fast path is left for a future optimisation
pass.

### Scratch slots

The lowering allocates six `_mf_*` fields once in the data section
(via `emitMemoryData`) and reuses them across **every** `memory.fill`
site in the program. Reuse is sound because each call body fully
writes each scratch before reading it, and `memory.fill` cannot be
nested inside another `memory.fill` (each site is one straight-line
instruction sequence with no calls):

| Field | Type | Role |
|---|---|---|
| `_mf_dst` | `SystemInt32` | snapshot of the popped `dst` operand |
| `_mf_val` | `SystemInt32` | snapshot of the popped `val` operand (full Int32; masked inside the byte-store helper) |
| `_mf_n`   | `SystemInt32` | snapshot of the popped `n` operand |
| `_mf_i`   | `SystemInt32` | loop induction variable |
| `_mf_addr` | `SystemInt32` | `dst + i` for the current iteration |
| `_mf_cmp`  | `SystemBoolean` | per-iteration `i < n` guard result |

The `_mf_*` family is intentionally distinct from `_mc_*` so
`memory.copy` and `memory.fill` never alias even if a future
optimisation pass interleaves them; per-site uniqueness is provided
by the loop labels.

### Per-call labels via `block_counter`

The two labels emitted per call (`__memfill_loop_<id>__`,
`__memfill_end_<id>__`) are uniqued by `Translator.block_counter`,
which the call increments at the start. Two `memory.fill` ops in the
same function therefore produce two disjoint label families even
though they share the underlying scratch fields.

### Skeleton (per call)

```uasm
    # snapshot operands
    PUSH, <wasm_stack_dst>; PUSH, _mf_dst; COPY
    PUSH, <wasm_stack_val>; PUSH, _mf_val; COPY
    PUSH, <wasm_stack_n>;   PUSH, _mf_n;   COPY

    # i := 0
    PUSH, __c_i32_0; PUSH, _mf_i; COPY

__memfill_loop_<id>__:
    # _mf_cmp := i < n
    PUSH, _mf_i; PUSH, _mf_n; PUSH, _mf_cmp
    EXTERN, "SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean"
    PUSH, _mf_cmp
    JUMP_IF_FALSE, __memfill_end_<id>__
    # _mf_addr := dst + i
    PUSH, _mf_dst; PUSH, _mf_i; PUSH, _mf_addr
    EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
    # mem[dst+i] := val   (byte-store helper masks to low 8 bits)
    # ... emitMemStoreByteAt(_mf_addr, _mf_val) ...
    PUSH, _mf_i; PUSH, __c_i32_1; PUSH, _mf_i
    EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
    JUMP, __memfill_loop_<id>__

__memfill_end_<id>__:
```

### Known limitations / future work

- **Pure byte loop, no bulk fast path.** Even when `dst` and `n` are
  word-aligned and lie within a single chunk, the current lowering
  still walks one byte at a time through the RMW byte-store helper.
  A future optimiser could detect alignment statically (or at runtime)
  and emit a `SystemUInt32Array.__Set__` per word, with a single
  pre-broadcast of the byte into all four lanes of a `SystemUInt32`.
  Until then, large `memory.fill` calls are O(n) in the number of
  EXTERN calls — roughly eight EXTERNs per byte filled — and will be
  visibly slower than a hand-rolled word loop.
- **Zero-length is naturally a no-op.** The first `i < n` test fails
  immediately at `i == 0` for `n == 0`, so the body is skipped without
  any special-case branching. The lowering still pays one comparison
  and one `JUMP_IF_FALSE` for the zero-length case.

## Passive data segments

The bulk-memory proposal generalises the Data section so each segment
carries a mode byte (see `docs/w3c_wasm_binary_format_note.md`
"Data segment modes"). The translator distinguishes two storage
strategies based on that mode.

### Active segments (mode `0x00`, mode `0x02` with `memidx == 0`)

Active segments are applied to linear memory **at translator-time** as
part of the existing `setupDataSegments` initialization pass: the
init bytes are written into the initial linear-memory page chunk(s)
exactly the way Core 1 segments already are. They need **no** runtime
field. The WASM 2.0 specification states that an active segment is
implicitly "dropped" immediately after the initial copy completes;
because the translator never materialises a backing field for an
active segment, that drop is a no-op (see "data.drop lowering" below).

### Passive segments (mode `0x01`)

Per passive segment (segment index `<idx>`, in declaration order from
the Data section), the translator declares two Udon fields in the data
section, named per the `__G__` namespace defined in
`docs/spec_variable_conversion.md`:

| Field | Type | Initial value | Role |
|---|---|---|---|
| `__G__data_seg_<idx>__bytes`   | `SystemByteArray` | translator-time literal containing the segment's `init` bytes | the segment payload that `memory.init` reads from |
| `__G__data_seg_<idx>__dropped` | `SystemBoolean`   | `false`                                                       | set to `true` by `data.drop`; checked at the head of every `memory.init` to honour WASM trap semantics |

Active segments do **not** receive these fields. The
`__dropped` flag therefore exists only for segments that the WASM
program can address through `memory.init` / `data.drop`.

### `SystemByteArray` materialisation

The `__G__data_seg_<idx>__bytes` array is sized to the exact length of
`segment.init` and populated at translator-time by emitting one
typed-array setter per byte (analogous to how the function table is
populated in `docs/spec_call_return_conversion.md` §7). The
implementer must verify against `docs/udon_nodes.txt` that
`SystemByteArray.__ctor__SystemInt32__SystemByteArray` and the
indexer-setter `SystemByteArray.__Set__SystemInt32_SystemByte__SystemVoid`
exist in the node table. **If `SystemByteArray` is not exposed**, the
documented fallback is to store the segment as a `SystemUInt32Array`
packed four bytes per word (little-endian, identical to how the linear
memory chunks are packed) and unpack each byte at `memory.init` time
with the same shift/mask sequence used by the byte load helper. The
choice between these two storage forms is a runtime decision; the
emitter should commit to one form per build and document which one it
chose in the generated header comment.

## memory.init lowering

`memory.init` consumes `(dst, src_off, n)` from the operand stack and
copies `n` bytes from the data segment identified by the immediate
`data_idx` into linear memory starting at `dst`. The data segment
must be a passive segment that has not yet been dropped; otherwise the
WASM specification requires a trap.

### Preconditions

- The segment must already have been declared by the data-section
  pass (i.e. `__G__data_seg_<data_idx>__bytes` and
  `__G__data_seg_<data_idx>__dropped` must exist in the emitted data
  section). The translator validates this at lowering time —
  `memory.init` against an unknown `data_idx`, or against an active
  segment that does not own a `__dropped` field, is a translation
  error.
- `data_idx` is a static immediate; the dispatch on which segment to
  read from is resolved entirely at translator-time, so the lowering
  inlines the segment field name directly into the generated EXTERN
  argument list — there is no runtime indirection through a "segment
  table".

### Scratch slots

Like `memory.copy` and `memory.fill`, the lowering allocates a single
shared `_mi_*` family in the data section and reuses it across **every**
`memory.init` site in the program. Reuse is sound for the same reason:
each call body fully writes each scratch before reading it, and
`memory.init` cannot be nested inside another `memory.init` (each site
is one straight-line instruction sequence with no calls).

| Field | Type | Role |
|---|---|---|
| `_mi_dst`  | `SystemInt32`   | snapshot of the popped `dst` operand |
| `_mi_src`  | `SystemInt32`   | snapshot of the popped `src_off` operand (offset within the segment) |
| `_mi_n`    | `SystemInt32`   | snapshot of the popped `n` operand |
| `_mi_i`    | `SystemInt32`   | loop induction variable |
| `_mi_addr` | `SystemInt32`   | `dst + i` for the current iteration (also reused as `src_off + i` for segment indexing) |
| `_mi_byte` | `SystemInt32`   | byte value loaded from the segment, forwarded into `emitMemStoreByteAt` |
| `_mi_cmp`  | `SystemBoolean` | per-iteration `i < n` guard, plus reused for the bounds-check and dropped-check booleans |

The `_mi_*` family is intentionally distinct from `_mc_*` and `_mf_*`
so `memory.init` never aliases `memory.copy` / `memory.fill` even if a
future optimisation pass interleaves them; per-site uniqueness is
provided by the loop labels.

### Per-call labels via `block_counter`

Three labels are emitted per call, uniqued by
`Translator.block_counter` (incremented at the start of the call):

- `__meminit_loop_<id>__` — head of the byte-copy loop
- `__meminit_end_<id>__`  — fall-through join after the loop
- `__meminit_trap_<id>__` — branch target for the dropped-check and
  bounds-check failures

Two `memory.init` ops in the same function therefore produce two
disjoint label families even though they share the underlying scratch
fields.

### Order of operations (per call)

1. **Snapshot operands** — pop `n`, `src_off`, `dst` off the WASM
   stack and `COPY` them into `_mi_n`, `_mi_src`, `_mi_dst`.
2. **Dropped check** — load `__G__data_seg_<idx>__dropped` and
   `JUMP_IF_FALSE` over the trap (so falling through means "not yet
   dropped, proceed"); on `true`, `JUMP, __meminit_trap_<id>__`.
3. **Bounds check (segment side)** — compute `_mi_src + _mi_n` and
   compare against the literal length of the segment (known at
   translator-time, emitted as a `__c_i32_<seg_len>__` constant).
   On overflow, `JUMP, __meminit_trap_<id>__`.
4. **Bounds check (memory side)** — compute `_mi_dst + _mi_n` and
   compare against `__G__memory_size_pages * 65536`. On overflow,
   `JUMP, __meminit_trap_<id>__`.
5. **Loop init** — `_mi_i := 0`.
6. **Loop body** at `__meminit_loop_<id>__`:
   - `_mi_cmp := _mi_i < _mi_n`; `JUMP_IF_FALSE __meminit_end_<id>__`.
   - `_mi_byte := __G__data_seg_<idx>__bytes[_mi_src + _mi_i]` via the
     `SystemByteArray` getter (or the packed-`SystemUInt32Array`
     fallback described above).
   - `_mi_addr := _mi_dst + _mi_i`.
   - Equivalent of `emitMemStoreByteAt(_mi_addr, _mi_byte)` — reuse
     the existing byte-store helper so chunk addressing and RMW
     semantics stay consistent.
   - `_mi_i := _mi_i + 1`.
   - `JUMP, __meminit_loop_<id>__`.
7. **Trap label** at `__meminit_trap_<id>__` — emit a host-trap call
   (when one is wired up) or, in the meantime, fall straight into
   `__meminit_end_<id>__` while leaving a translator comment marking
   the spec-mandated trap site. The choice is left to the emitter so
   long as it is documented in the generated assembly.
8. **Join label** at `__meminit_end_<id>__`.

### Skeleton (per call)

```uasm
    # snapshot operands
    PUSH, <wasm_stack_dst>;     PUSH, _mi_dst; COPY
    PUSH, <wasm_stack_src_off>; PUSH, _mi_src; COPY
    PUSH, <wasm_stack_n>;       PUSH, _mi_n;   COPY

    # dropped check: if __G__data_seg_<idx>__dropped == true → trap
    PUSH, __G__data_seg_<idx>__dropped
    JUMP_IF_FALSE, __meminit_dropped_ok_<id>__
    JUMP, __meminit_trap_<id>__
__meminit_dropped_ok_<id>__:

    # bounds checks (segment side, memory side) ... → trap on failure

    # i := 0
    PUSH, __c_i32_0; PUSH, _mi_i; COPY

__meminit_loop_<id>__:
    PUSH, _mi_i; PUSH, _mi_n; PUSH, _mi_cmp
    EXTERN, "SystemInt32.__op_LessThan__SystemInt32_SystemInt32__SystemBoolean"
    PUSH, _mi_cmp
    JUMP_IF_FALSE, __meminit_end_<id>__

    # _mi_addr := src_off + i  (segment index)
    PUSH, _mi_src; PUSH, _mi_i; PUSH, _mi_addr
    EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
    # _mi_byte := __G__data_seg_<idx>__bytes[_mi_addr]
    PUSH, __G__data_seg_<idx>__bytes; PUSH, _mi_addr; PUSH, _mi_byte
    EXTERN, "SystemByteArray.__Get__SystemInt32__SystemByte"

    # _mi_addr := dst + i  (memory address)
    PUSH, _mi_dst; PUSH, _mi_i; PUSH, _mi_addr
    EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
    # ... emitMemStoreByteAt(_mi_addr, _mi_byte) ...

    PUSH, _mi_i; PUSH, __c_i32_1; PUSH, _mi_i
    EXTERN, "SystemInt32.__op_Addition__SystemInt32_SystemInt32__SystemInt32"
    JUMP, __meminit_loop_<id>__

__meminit_trap_<id>__:
    # host-trap call (if wired) — otherwise fall through with a
    # translator comment marking the spec-mandated trap site.

__meminit_end_<id>__:
```

### Known limitations / future work

- **Pure byte loop, no bulk fast path.** Even when `dst`, `src_off`,
  and `n` are word-aligned, the lowering still walks one byte at a
  time. A future optimiser could detect alignment and emit a
  `SystemUInt32Array.__Set__` per word once the underlying segment
  storage matches.
- **`data_idx` must resolve at translator-time.** The bulk-memory
  spec already requires `data_idx` to be a static immediate, so this
  is not a translator-imposed restriction — it is just worth noting
  that the dispatch on which segment to read from is fully resolved
  at compile time.
- **Trap implementation is open.** The `__meminit_trap_<id>__` label
  is reserved by this lowering, but the actual trap mechanism (a
  host extern call vs. a no-op vs. setting a global error flag) is
  deferred to the implementer; the spec only requires that the
  observable behaviour for an in-bounds, not-yet-dropped segment is
  the byte copy described above.

## data.drop lowering

`data.drop` has no operand-stack effect. Its single immediate is the
`data_idx` of the segment to mark as dropped.

### Lowering

- **Passive segments** (mode `0x01`): emit one `COPY` that sets
  `__G__data_seg_<idx>__dropped := true`. Concretely, the constant
  `__c_bool_true__` (already provided by the shared common-data
  block when boolean constants are needed; otherwise materialise a
  one-shot `SystemBoolean` literal via the standard initial-value
  rules in `docs/udon_specs.md` §4.7) is copied into the dropped
  flag. No labels and no scratch are required.
- **Active segments** (mode `0x00` or mode `0x02` with `memidx == 0`):
  WASM 2.0 defines `data.drop` on an active segment as a no-op,
  because active segments are conceptually already dropped after
  their instantiation-time copy. The translator emits a single
  comment of the form `# data.drop on active segment <idx>: no-op`
  and nothing else; in particular, no field is read or written.

### Skeleton (passive segment)

```uasm
    # __G__data_seg_<idx>__dropped := true
    PUSH, __c_bool_true__
    PUSH, __G__data_seg_<idx>__dropped
    COPY
```

### Skeleton (active segment)

```uasm
    # data.drop on active segment <idx>: no-op
```

### Interaction with `memory.init`

A passive segment whose `__dropped` flag is `true` causes any
subsequent `memory.init` against it to take the trap branch defined
in the lowering above. There is no Udon-level "free the storage"
operation — the `SystemByteArray` field remains live in the data
section even after a `data.drop`, because Udon has no way to release
a typed-array field at runtime. The flag is therefore the sole
mechanism that distinguishes "dropped" from "not yet dropped".

## Open Questions and Constraints

- Shared memory and the threads proposal are not supported; loads and stores emit no fence/atomic semantics.
- The memory64 proposal is not supported; addresses are always `SystemInt32`.
- Atomic memory instructions (`memory.atomic.*`) are not supported.
- Straddling accesses (i64 or unaligned i32 that cross a page boundary) require two outer `GetValue` calls. The translator should emit a straddle-safe path unless alignment can be statically proven.
- `SystemBitConverter` EXTERN names used for float reinterpretation have not been enumerated here; they are documented alongside float support in a separate spec revision.
- A word-aligned fast path for `memory.copy` and `memory.fill` is
  open work — the current byte-only loops are correct but pay per-byte
  EXTERN overhead even when the operands are trivially aligned.

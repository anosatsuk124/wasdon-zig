# Linear Memory Conversion

## 1. Problem

WebAssembly linear memory is a growable array of bytes that any load or store
may address at any offset, with any width, aligned or not. Udon has no raw
memory: only typed heap slots, .NET arrays, and externs.

Every memory access in translated code therefore becomes one or more `EXTERN`
calls, and `EXTERN` is the expensive instruction on the Udon VM
(`docs/udon_vm.md`). The model is chosen to minimize externs per access.

## 2. Model

Linear memory is **one `SystemByteArray`**.

```
__G__memory:            %SystemByteArray, null     # allocated by the init routine
__G__memory_size_pages: %SystemInt32, <initial pages>
```

- Addresses are array indices; no decomposition, no alignment cases, no
  page-straddling cases.
- Multi-byte reads use `System.BitConverter`, which reads little-endian at
  any index — exactly WASM's byte order.
- Multi-byte writes use `System.Buffer.BlockCopy`, which copies raw bytes
  between arrays of primitive types.
- An out-of-range access raises a .NET exception inside the extern, which
  halts the UdonBehaviour — the Udon equivalent of a WASM trap. No bounds
  checks are emitted.

`__udon_meta.options.memory.udonName` renames the array; the size variable
is `<name>_size_pages`.

## 3. Loads

`mem` is the memory array, `a` the effective address (§5).

| Instruction | Externs |
|---|---|
| `i32.load` | `BitConverter.ToInt32(mem, a)` |
| `i64.load` | `BitConverter.ToInt64(mem, a)` |
| `f32.load` | `BitConverter.ToSingle(mem, a)` |
| `f64.load` | `BitConverter.ToDouble(mem, a)` |
| `i32.load8_u` | `SystemByteArray.Get(mem, a)` → `Convert.ToInt32(Byte)` |
| `i32.load8_s` | as `load8_u`, then `<< 24`, `>> 24` |
| `i32.load16_u` | `BitConverter.ToUInt16` → `Convert.ToInt32(UInt16)` |
| `i32.load16_s` | `BitConverter.ToInt16` → `Convert.ToInt32(Int16)` |
| `i64.load8_u` | `SystemByteArray.Get` → `Convert.ToInt64(Byte)` |
| `i64.load8_s` | as `i32.load8_s`, then `Convert.ToInt64(Int32)` |
| `i64.load16_u` / `_s` | `BitConverter.ToUInt16` / `ToInt16` → `Convert.ToInt64` |
| `i64.load32_u` | `BitConverter.ToUInt32` → `Convert.ToInt64(UInt32)` |
| `i64.load32_s` | `BitConverter.ToInt32` → `Convert.ToInt64(Int32)` |

The intermediate value of a two-step load lives in a temporary of its own
.NET type (`SystemByte`, `SystemUInt16`, …): slots are never read as a type
other than the one last written (`docs/udon_vm.md` §3).

### Pending loads

A load is not emitted when its instruction is lowered. It stays on the
translation-time operand stack as a *pending* entry — "the value at this
address" — and is emitted only when something needs the value. That lets
the consumer do better than "read, then use":

| The loaded value is… | Emitted instead | Externs |
|---|---|---:|
| stored straight back (`load` then `store` of at most the loaded width) | `Buffer.BlockCopy(mem, src, mem, dst, n)` | 1, not 3–4 |
| a byte tested for zero (`if`, `br_if`, `select`, `eqz`, `== 0`, `!= 0`) | `BitConverter.ToBoolean(mem, a)` | 1, not 3 |
| a byte combined with another byte or a constant 0–255 by `+ - * & \| ^ << >>` or a comparison | `SystemByteArray.Get` then the `SystemByte` operator | 2, not 3 |
| anything else | the load from the table above | |

`SystemByte` operators take two bytes and return `Int32` (or `Boolean`), as
C# computes them on `int`s; they are the i32 results, and they absorb the
`Convert.ToInt32` each operand would otherwise need. Byte constants cannot
be literals, so each one used is converted from an `Int32` constant during
initialization (`__c_u8_{value}`).

A pending load must still read memory as it was when the load instruction
ran. It is emitted before anything that could change the answer:

- any store, `memory.copy`, `memory.fill`, `memory.grow`;
- any call, direct, indirect or to an extern (an extern can write memory
  through the array, `docs/spec_host_import_conversion.md`);
- the start of a `block`, `loop` or `if`;
- an assignment to the local its address is based on.

Its address must be stable for it to stay pending at all: a constant, a
local, or a temporary the entry owns. A load from any other address (a
global, say) is emitted at once.

Deferral means an out-of-bounds load whose value is never used (`drop`)
does not fault, and one that is used faults where it is used rather than
where it was written. WASM traps at the load; here the event ends either
way.

## 4. Stores

.NET has no "write these four bytes" call that takes an `int`. The
translator keeps one single-element array per value type,

```
__st_i32: %SystemInt32Array     __st_f32: %SystemSingleArray
__st_i64: %SystemInt64Array     __st_f64: %SystemDoubleArray
```

allocated once by the init routine and declared only if used. A store is

```
SystemInt32Array.Set(__st_i32, 0, value)
Buffer.BlockCopy(__st_i32, 0, mem, a, n)        # n = 1, 2, 4 or 8
```

Because the element is little-endian in memory, copying its first `n` bytes
is exactly `store8` / `store16` / `store32`. Every store is two externs and
allocates nothing.

**Constant stores are one extern.** The bytes of a constant are placed in
the constant pool (`docs/spec_numeric_conversion.md` §5), and the store is

```
Buffer.BlockCopy(__kpool, <offset>, mem, a, n)
```

## 5. Effective address

`a = base + memarg.offset`. When the base is a constant the sum is folded;
when the offset is zero the base slot is used directly; otherwise one
`SystemInt32.op_Addition` computes it.

**Derived values are remembered.** When the base is a local, the sum goes
to one of eight shared slots (`__derived0` … `__derived7`) together with a
note of which local and offset it is. A later access to the same field —
the store of `p.x += v` after its load, say — finds the note and reuses the
slot. The same cache holds `local ^ 0x80000000`, the operand of an unsigned
comparison (`docs/spec_numeric_conversion.md` §3). A note is dropped when
its local is assigned, and all of them at every label (other paths lead
there) and after every call (the callee uses the same slots, and an extern
may run another event of the behaviour).

## 6. Bulk memory

| Instruction | Lowering |
|---|---|
| `memory.copy` | `Buffer.BlockCopy(mem, src, mem, dst, n)` — overlap-safe, as required |
| `memory.fill` with constant 0 | `Array.Clear(mem, dst, n)` |
| `memory.fill` otherwise | runtime routine: write one byte, then double the filled prefix with `BlockCopy` (⌈log₂ n⌉ + 2 externs) |
| `memory.init`, `data.drop` | not supported (passive segments) |

Producers should enable bulk memory (`docs/producer_guide.md` §1): without
it `memcpy` / `memset` are byte loops costing several externs per byte.

## 7. `memory.size` and `memory.grow`

`memory.size` reads `__G__memory_size_pages`.

`memory.grow` calls a runtime routine, emitted once if any function uses it:

```
new = pages + delta
if new > max_pages or new < pages: return -1
arr = new byte[new << 16]
Buffer.BlockCopy(mem, 0, arr, 0, pages << 16)
mem = arr; old = pages; pages = new; return old
```

Growth copies the existing contents once; .NET zero-fills the new part.

## 8. Initialization

The init routine (`docs/spec_call_return_conversion.md` §7):

1. `mem = new byte[initial_pages << 16]`.
2. For each active data segment, with leading and trailing zero bytes
   trimmed:

   ```
   __data_N: %SystemString, "<Base64 of the bytes>"
   Convert.FromBase64String(__data_N) → __data_bytes
   Buffer.BlockCopy(__data_bytes, 0, mem, <offset>, <length>)
   ```

   Two externs per segment regardless of its size.
3. Memory-backed fields (`docs/spec_udonmeta_conversion.md`) are written
   after the segments.

Segment offsets must be constant expressions.

## 9. Sizing

- `initial pages` = max(module minimum, `options.memory.initialPages`, pages
  needed to hold every data segment).
- `max pages` = `options.memory.maxPages`, else the module's declared
  maximum, else `Options.default_max_pages` (1024 = 64 MiB); never below the
  initial size, and at most 32767 (the array is indexed by `Int32`).

`maxPages` only bounds `memory.grow`; nothing is preallocated for it.

## 10. Passing memory to externs

A `__udon_meta` field with `source.kind = "import"` whose `udonName` is the
memory variable's name yields the `byte[]` itself as a handle
(`docs/spec_host_import_conversion.md` §6). WASM code can then hand regions
of its memory to externs without per-element copies — for example
`Buffer.BlockCopy(memory, ptr, pixels, 0, n)` followed by
`Texture2D.LoadRawTextureData(pixels)`.

`SystemString` arguments are decoded straight out of memory with
`Encoding.UTF8.GetString(mem, ptr, len)` — one extern.

## 11. History: the two-level `uint[]` model

Until commit `7d44799` memory was an `object[]` of 64 KiB `uint[]` pages.
That design assumed `SystemByteArray` and `BitConverter` were unavailable;
both are in the node list. It needed address decomposition (shift, mask,
shift), two array reads, an alignment/straddle dispatch, and — because slots
are strictly typed — a `BitConverter.GetBytes` + `ToInt32` round trip to move
each loaded `UInt32` into an `Int32` slot.

| Access | two-level `uint[]` | `byte[]` |
|---|---:|---:|
| aligned `i32.load` | 8 externs | 1 |
| `i32.load8_u` | 9 | 2 |
| `i32.store` | 9 | 2 (1 for a constant) |
| `i32.store8` | 14 | 2 |
| data segment of *n* bytes | ≈ *n*/4 × 2 | 2 |
| `memcpy` of *n* bytes | ≈ 20 *n* | 1 (bulk memory) |

Measured effect on whole programs is in `docs/benchmarks.md`.

## 12. Limits

- At most 2 GiB − 64 KiB of memory.
- One memory; no shared memory, no atomics, no memory64.
- Passive data segments are rejected.

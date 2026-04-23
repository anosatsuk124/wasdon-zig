# Host Import Conversion Strategy

## Problem

WebAssembly modules declare their host interface through an **import section**: each import is a `(module, name)` pair plus a function type (`docs/w3c_wasm_binary_format_note.md`). WASM places no constraint on what the importer does with those names, and in particular nothing ties them to Udon's extern machinery.

The Udon VM, by contrast, invokes .NET methods exclusively through the `EXTERN` instruction with a **signature string** (`docs/udon_specs.md` §6.2.6, §7). The only way a WASM-originated call can reach a real `.NET` method is for the translator to emit an `EXTERN` with the corresponding signature.

The translator's first iteration hard-coded a single mapping:

```
(env, ConsoleWriteLine, (i32, i32) -> ())
   ↓
EXTERN, "SystemConsole.__WriteLine__SystemString__SystemVoid"
```

This breaks down for any other host function. Each additional mapping would require editing the translator's source, which is unacceptable for a library-oriented tool — downstream users should not need to patch `wasdon-zig` to add a new extern.

## Solution Overview

Let the **WASM import name itself carry the Udon extern signature**. The translator parses the name; if it matches the grammar in `docs/udon_specs.md` §7.1–§7.2, it is pass-through material, and the translator synthesizes the `PUSH` / `EXTERN` / `COPY` sequence automatically. No table, no hard-coded names.

On the WASM producer side this is a single change — Zig's raw-identifier syntax (`@"..."`) lets the author write:

```zig
extern "env" fn @"SystemConsole.__WriteLine__SystemString__SystemVoid"(
    ptr: [*]const u8,
    len: usize,
) void;
```

The `env.` module prefix is conventional; anything is accepted. LLVM emits the import verbatim, and the translator sees the literal signature string as `imp.name`.

Non-signature import names (`foo`, `print`, etc.) fall through to a diagnostic path (strict mode → translation error; lenient mode → `ANNOTATION, __unsupported__`).

This strategy mirrors the decision already taken for non-imported `EXTERN` calls: `docs/spec_call_return_conversion.md` §11 assembles signature strings at translation time for arithmetic operators; this document extends the same rule to host-originated calls.

## Signature Grammar (reprise of §7)

The grammar accepted by the parser, restated in ABNF for precision:

```
signature       = udon-type ".__" method "__" arg-list "__" return-type
udon-type       = 1*( letter / digit )           ; namespace+type, no separators
method          = 1*( letter / digit / "_" )     ; single `_` allowed; no `__`
arg-list        = %s"SystemVoid"                 ; nullary
                / udon-type *( "_" udon-type )   ; one or more args
return-type     = udon-type
```

Each `udon-type` may carry the suffix `Array` (array type) or `Ref` (in/out pass-by-reference). `Ref` is **stripped** from the recorded type and surfaced as a boolean flag on the argument (see §3 below).

The method name `ctor` denotes a constructor (§7.2). The grammar is otherwise identical to the rules in `docs/udon_specs.md` §7.2.

### Non-signature rejection

A name is **not** a signature (and parsing returns `null`) if:

- It does not contain `.__`.
- Any `__`-delimited segment after the `.__` split is empty, other than the reserved nullary `SystemVoid` form.
- A `udon-type` in the argument or return position starts with a non-letter.

## Solution Details

### 1. Parser

A new module `src/translator/extern_sig.zig` exposes a pure function:

```zig
pub const ArgKind = enum { direct, marshal_string };

pub const ArgSpec = struct {
    udon_type: []const u8,   // e.g. "SystemInt32", "SystemStringArray"
    kind: ArgKind,
    is_ref: bool = false,    // `Ref` suffix detected
};

pub const Signature = struct {
    udon_type: []const u8,
    method: []const u8,
    args: []const ArgSpec,   // empty slice for nullary
    result: []const u8,      // "SystemVoid" for void
    raw: []const u8,         // original name, reused as EXTERN immediate
};

pub fn parse(
    allocator: std.mem.Allocator,
    name: []const u8,
) std.mem.Allocator.Error!?Signature;
```

Parsing is allocation-light: all slices alias into `name`. The only heap use is the `args` array.

### 2. WASM ↔ Udon Type Mapping

For each parsed `ArgSpec`, the generic dispatcher validates the WASM parameter sequence. The mapping is strict — unexpected shapes are a translation error, not a silent coercion.

| Udon type | WASM params consumed | `ArgKind` | Notes |
|---|---|---|---|
| `SystemInt32`, `SystemUInt32` | 1 (`i32`) | `direct` | |
| `SystemInt64`, `SystemUInt64` | 1 (`i64`) | `direct` | Udon stack slot stores the 64-bit handle (`docs/udon_specs.md` §4.7 reiterates init restrictions but runtime handling is unconstrained). |
| `SystemSingle` | 1 (`f32`) | `direct` | |
| `SystemDouble` | 1 (`f64`) | `direct` | |
| `SystemBoolean` | 1 (`i32`) | `direct` | WASM carries booleans as i32; the translator emits no explicit comparison-to-zero unless the callee expects a `SystemBoolean` slot (see §5). |
| `SystemString` | 2 (`i32`, `i32`) | `marshal_string` | Consumed as `(ptr, len)` and fed through the decoding helper (§3). |
| `*Array` types | 1 (`i32`) | `direct` | The WASM-side representation is an opaque handle index resolved to the Udon heap slot by the host (implementation-specific; the translator merely passes the i32 through). |
| `*Ref` (any base) | 1 (`i32`) | `direct`, `is_ref=true` | The i32 is interpreted as a linear-memory byte address; the translator emits read-modify-write around the call per §4 below. |

Return type resolution uses the same table. `SystemVoid` consumes no return slot.

### 3. `SystemString` Marshaling Helper

The two-level chunked memory model (`docs/spec_linear_memory.md`) stores WASM bytes as packed `SystemUInt32` words. Before a `SystemString` argument can be passed to an extern, those bytes must be decoded as UTF-8 and materialized as a `.NET` `System.String`.

**Data declarations (emitted once, shared across all call sites):**

```
_marshal_str_ptr:       %SystemInt32, 0
_marshal_str_len:       %SystemInt32, 0
_marshal_str_bytes:     %SystemByteArray, null
_marshal_str_tmp:       %SystemString, null
_marshal_str_i:         %SystemInt32, 0
_marshal_str_addr:      %SystemInt32, 0
_marshal_str_byte:      %SystemByte, 0
_marshal_str_cond:      %SystemBoolean, null
_marshal_encoding_utf8: %SystemObject, null   # cached UTF-8 Encoding instance
```

**One-shot cache (emitted once in memory-init, before any call site):**

```
# encoding := Encoding.UTF8 (static property getter).
PUSH, _marshal_encoding_utf8
EXTERN, "SystemTextEncoding.__get_UTF8__SystemTextEncoding"
```

**Helper pattern (inline at each call site):**

```
# (a) Copy stacked (ptr, len) into the named scratch slots.
#     `caller_S{n-2}` holds ptr; `caller_S{n-1}` holds len.
PUSH, caller_S{n-2}
PUSH, _marshal_str_ptr
COPY

PUSH, caller_S{n-1}
PUSH, _marshal_str_len
COPY

# (b) Allocate a SystemByteArray of length `len`.
PUSH, _marshal_str_len
PUSH, _marshal_str_bytes
EXTERN, "SystemByteArray.__ctor__SystemInt32__SystemByteArray"

# (c) Byte-copy loop: for i in 0..len { bytes[i] = *(byte*)(ptr + i) }.
#     Each iteration reuses the i32.load8_u shift/mask preamble to extract
#     a byte from the chunked memory model, then converts UInt32 → Int32 →
#     SystemByte (udon_nodes.txt has no direct SystemUInt32→SystemByte).

# (d) Decode as UTF-8. GetString is a non-static method; the encoding
#     instance is PUSHed first as `this` (§6.2.6 of docs/udon_specs.md).
PUSH, _marshal_encoding_utf8   # this
PUSH, _marshal_str_bytes       # byte[] arg
PUSH, _marshal_str_tmp         # out-result
EXTERN, "SystemTextEncoding.__GetString__SystemByteArray__SystemString"
```

The translator substitutes `_marshal_str_tmp` for the `SystemString` argument in the outer `EXTERN`'s argument list.

Multiple `SystemString` arguments in one call re-use the same helper variables sequentially — each argument is marshaled, immediately `PUSH`-ed before the outer `EXTERN`, and the scratch slots are overwritten by the next argument.

### 4. `*Ref` / `*Out` Arguments

`Ref` / `Out` arguments in Udon accept a heap slot that is written to by the callee (`docs/udon_specs.md` §6.2.6). When the WASM side passes a pointer (i32 byte address), the translator:

1. Allocates a temporary slot of the base type (e.g. `_marshal_ref_int32_0: %SystemInt32, 0`).
2. (For `Ref`, not `Out`) Reads the current value from linear memory into that slot before the call.
3. `PUSH`es the temporary as the argument.
4. After the `EXTERN`, writes the temporary's value back to the same linear-memory address.

Ref support is declared here for completeness but is **not** required by the initial implementation (bench.wasm has no ref arguments).

### 5. Dispatcher Ordering

A new module `src/translator/lower_import.zig` centralizes host import handling. The dispatch precedence at each `call <imp>` site is:

1. **`imp.name` parses as a full signature** (most common). Invoke `emitGenericExtern(sig, imp_ty)`.
2. **`imp.module` + "." + `imp.name` parses as a full signature** (future extension for tooling that splits the signature on the `.__` boundary). Retry parsing on the concatenation.
3. **Neither parses.** Emit `ANNOTATION, __unsupported__` with a diagnostic comment, unless `__udon_meta.options.strict` is set, in which case raise a translation error.

Rule (2) is declared here for completeness; the first implementation only performs (1) and (3).

## Worked Example

### WASM source

```zig
extern "env" fn @"SystemConsole.__WriteLine__SystemString__SystemVoid"(
    ptr: [*]const u8,
    len: usize,
) void;

export fn on_interact() void {
    const msg = "hi";
    @"SystemConsole.__WriteLine__SystemString__SystemVoid"(msg.ptr, msg.len);
}
```

### Translator output (code section, abbreviated)

```
# --- call @"SystemConsole.__WriteLine__SystemString__SystemVoid"(ptr, len) ---

# (a) Marshal (ptr, len) into SystemString
PUSH, __on_interact_S0__     # ptr
PUSH, _marshal_str_ptr
COPY
PUSH, __on_interact_S1__     # len
PUSH, _marshal_str_len
COPY
PUSH, _marshal_str_len
PUSH, _marshal_str_bytes
EXTERN, "SystemByteArray.__ctor__SystemInt32__SystemByteArray"
# ... chunk loop copying `len` bytes into _marshal_str_bytes ...
PUSH, _marshal_encoding_utf8   # this (UTF-8 encoding singleton)
PUSH, _marshal_str_bytes
PUSH, _marshal_str_tmp
EXTERN, "SystemTextEncoding.__GetString__SystemByteArray__SystemString"

# (b) Actual extern call
PUSH, _marshal_str_tmp
EXTERN, "SystemConsole.__WriteLine__SystemString__SystemVoid"
```

No return-value handling is needed because the signature's return type is `SystemVoid`.

### Translator output (data section, relevant additions)

```
_marshal_str_ptr:       %SystemInt32, 0
_marshal_str_len:       %SystemInt32, 0
_marshal_str_bytes:     %SystemByteArray, null
_marshal_str_tmp:       %SystemString, null
_marshal_str_i:         %SystemInt32, 0
_marshal_str_addr:      %SystemInt32, 0
_marshal_str_byte:      %SystemByte, 0
_marshal_str_cond:      %SystemBoolean, null
_marshal_encoding_utf8: %SystemObject, null
```

## Alignment with `__udon_meta`

The metadata schema (`docs/spec_udonmeta_conversion.md`) already models function-level bindings for *exported* WASM functions. Imports are currently unrepresented. A future extension may add:

```json
{
  "imports": {
    "log": {
      "source": { "kind": "import", "module": "env", "name": "log" },
      "extern": "UnityEngineDebug.__Log__SystemObject__SystemVoid"
    }
  }
}
```

to let a WASM author keep friendly names (`log`) while the metadata routes them to an Udon signature. The grammar-based auto-discovery in this document is additive — the two mechanisms compose by layering metadata lookup **before** signature parsing in the dispatcher.

## Constraints and Cautions

- **`EXTERN` caches optimization data in the name slot.** (`docs/udon_specs.md` §6.2.6, §12.) The anonymous string variable the assembler synthesizes for the immediate is fine to reuse across invocations; the translator must not share that slot with any user variable.
- **The `_marshal_str_tmp` variable is overwritten on every string-marshaling call.** Callers must treat it as a short-lived scratch; do not cache the heap index elsewhere.
- **SystemString init restrictions** (`docs/udon_specs.md` §4.7). `_marshal_str_tmp` is declared with initial value `null`; the first `GetString` EXTERN populates it before any read.
- **UTF-8 validation.** This spec delegates validation to the decoding `EXTERN`. Translators targeting stricter hosts should precede the call with a bounds check against linear memory size.
- **Name clash with numeric dispatch.** `lower_numeric.zig` currently hand-writes signature strings for WASM arithmetic (`i32.add` → `SystemInt32.__op_Addition__...`). Those strings must pass the same parser; a regression test loops the existing table through `extern_sig.parse` to catch drift.
- **Widening aliases in the final EXTERN.** Some .NET methods expose only a broader overload on Udon even though a narrower one is legal in C# (e.g. `UnityEngine.Debug.Log(string)` is only exposed as `UnityEngineDebug.__Log__SystemObject__SystemVoid`). The translator keeps the narrower signature in the WASM import name — so marshaling still kicks in for `SystemString` args — but rewrites the final `EXTERN` immediate through a small alias table in `lower_import.zig`'s `resolveSignatureAlias`. `System.String` is-a `System.Object`, so passing the marshaled string to the Object overload is a legal implicit widening at runtime. Authors can rely on `__Log__SystemString__SystemVoid` in their import name without seeing a `not implemented yet` error from Udon.
- **LLVM-emitted import names.** The Zig compiler preserves raw-identifier names verbatim when emitting WASM; no symbol mangling is applied for `extern "<module>" fn` declarations. Authors relying on other compilers (Rust, C) must verify the same round-trips.

## Future Work

- Generic support (`T`, `SystemType` extra args) per `docs/udon_specs.md` §7.4.
- `VRCInstantiate` and other "falsified" Udon type names (§7.4).
- `VRCUdon.UdonBehaviour` → `VRCUdonCommonInterfacesIUdonEventReceiver` rewrite (§3.4) at parse time.
- Extern-existence checks against a shipped whitelist.

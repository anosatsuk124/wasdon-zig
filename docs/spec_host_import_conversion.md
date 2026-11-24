# Host Import Conversion

## 1. Problem

A WASM module reaches its host through function imports, each a
`(module, name)` pair with a WASM function type. The Udon VM reaches .NET
only through `EXTERN` with a signature string (`docs/udon_specs.md` §7).
The translator has to turn the first into the second without a per-import
table that would need editing for every new extern.

## 2. The import name is the extern signature

An import whose **name** is an Udon extern signature is called as that
extern. Nothing else is declared anywhere.

```zig
extern "env" fn @"UnityEngineTransform.__set_position__UnityEngineVector3__SystemVoid"(self: i32, pos: i32) void;
```

```rust
#[link(wasm_import_module = "env")]
unsafe extern "C" {
    #[link_name = "UnityEngineTransform.__set_position__UnityEngineVector3__SystemVoid"]
    fn transform_set_position(this: i32, pos: i32);
}
```

The signature grammar is `<Type>.__<method>__<arg>_<arg>…__<ret>`, with the
argument list omitted or `SystemVoid` for no arguments; see
`src/udon/nodes.zig` (`parseSignature`). An import that is neither a
signature nor bound by `__udon_meta` (§6) is a translation error.

**Existence check.** The signature is looked up in the node list
(`docs/udon_nodes.txt`). A missing node would make the program load and
then silently never run (`docs/udon_specs.md` §7.4), so the translator
warns, or fails with `options.strict` / `--strict`.

**String overloads.** Udon sometimes exposes only the `SystemObject`
overload of a method commonly called with a string (`Debug.Log`). A
signature written with `SystemString` that is not in the node list is
redirected to the same signature with `SystemObject` if that exists; the
argument is still marshalled as a string.

## 3. Mapping WASM parameters to extern operands

The WASM parameters are matched to the signature left to right.

### Receiver

A signature does not say whether the method is static. Instance methods
take the receiver as an extra **leading** WASM parameter. The translator
decides from the parameter count: with *A* signature arguments, *A* WASM
parameters means static and *A* + 1 means instance. Constructors (`ctor`)
and operators (`op_*`) are always static.

### Argument types

| Signature type | WASM parameter(s) | Passed as |
|---|---|---|
| `SystemInt32`, `SystemInt64`, `SystemSingle`, `SystemDouble` | `i32`, `i64`, `f32`, `f64` | the slot itself |
| `SystemBoolean` | `i32` | the `Boolean` if the value is a comparison result, else `Convert.ToBoolean(Int32)` |
| `SystemByte`, `SystemSByte`, `SystemInt16`, `SystemUInt16`, `SystemChar` | `i32` | `Convert.To<T>(Int32)` (range-checked) |
| `SystemUInt32`, `SystemUInt64` | `i32`, `i64` | bit reinterpretation (`BitConverter.GetBytes` + `ToUInt32/64`) |
| `SystemString` | `i32, i32` (pointer, length) | `Encoding.UTF8.GetString(memory, ptr, len)` |
| `SystemString` | `i32` | a string handle (see below) |
| `<T>Ref` (`ref` / `out`) of a 32/64-bit scalar | `i32` (address) | a temporary loaded from that address before the call and stored back after |
| anything else | `i32` | an opaque handle |

**Strings.** If the parameter count fits "every `SystemString` is a
(pointer, length) pair", strings are marshalled from linear memory — one
extern each. If it fits "one parameter per argument", they are handles.
With exactly one string argument the two readings can collide (*A* + 1
parameters is both "static, marshalled" and "instance, handle"); the
marshalled reading wins. Importing from module `udon.instance` or
`udon.static` forces the receiver convention and removes the ambiguity.

**Generic methods** (`T` / `TArray` in the signature) take hidden
`SystemType` operands. Extra trailing WASM parameters are passed through
unchanged so the producer can supply them (for example from
`SystemType.__GetType__SystemString__SystemType`).

### Results

| Signature return | WASM result | |
|---|---|---|
| `SystemVoid` | none | |
| `SystemInt32`, `SystemInt64`, `SystemSingle`, `SystemDouble` | `i32`, `i64`, `f32`, `f64` | written straight to its destination |
| `SystemBoolean` | `i32` | stays a `Boolean` until used as a number; `if (extern())` is one extern |
| narrow integers | `i32` | `Convert.ToInt32` |
| `SystemUInt32`, `SystemUInt64` | `i32`, `i64` | bit reinterpretation |
| anything else | `i32` | an opaque handle |

A WASM import may declare no result for a method that returns one; the
result is discarded.

## 4. Handles

Udon object and struct types (`UnityEngineTransform`, `UnityEngineVector3`,
`SystemString`, arrays, …) have no WASM representation. They travel as
**opaque `i32` handles**: the WASM value is an Udon heap slot that holds
the object. This works because Udon slots are dynamically typed and `COPY`
carries the type along (`docs/udon_vm.md` §3).

Rules for producers:

- **Never do arithmetic or comparisons on a handle.** It is not a number;
  reading it as `Int32` halts the behaviour. Test for null with an extern
  (`VRCSDKBaseUtilities.__IsValid__SystemObject__SystemBoolean`).
- **Never store a handle in linear memory** — not in a struct, an array, a
  `static`, or anything whose address is taken. Memory holds bytes; the
  object would be lost and the store would fault. Keep handles in locals,
  pass them as arguments, return them, or keep them in an Udon variable
  (§6).

Results of handle type are written to temporaries declared with the Udon
type the signature names, so each slot keeps one type.

**Strings are handles too** when they are not marshalled: a `SystemString`
result, or a string argument in the one-parameter-per-argument form, is a
.NET string held by Udon. A program can build text entirely on the Udon
side — `String.Concat(a, b)`, `Int32.ToString()`, `Debug.Log(object)` — at
one extern per operation, which is how UdonSharp code does it and is far
cheaper than assembling bytes in linear memory. `String.Copy(ptr, len)`
turns bytes into such a handle.

## 5. Enum arguments

Udon Assembly cannot create a non-zero enum value: the assembler only
initializes enum variables to `null` (the default, 0), and Udon exposes no
conversion from integer to enum. Three ways around it:

- an overload without the enum parameter (`Texture2D(int, int)`);
- **the enum's zero value**, from a variable that is never assigned: a
  field of the enum's type bound to a getter import
  (`"type": "UnityEngineFilterMode"` reads as `FilterMode.Point`);
- **a value read from an object that has it**: `Texture2D.format` of a
  texture made by the two-argument constructor is `RGBA32`, which can then
  be passed to the four-argument one.

`examples/udon/udon.zig` (`newTexture`) uses the last two to make an
RGBA32, mipmap-free, point-filtered texture at run time. Failing all that,
receive the value in an Udon variable assigned in the Inspector.

## 6. Udon variables as imports

`__udon_meta.fields` can bind a function import to an Udon variable instead
of an extern (`docs/spec_udonmeta_conversion.md`):

```json
"texture": {
  "source": { "kind": "import", "module": "env", "name": "udon.texture", "setter": "udon.set_texture" },
  "udonName": "_texture", "type": "UnityEngineTexture2D", "export": true
}
```

```zig
extern "env" fn @"udon.texture"() i32;          // read  _texture
extern "env" fn @"udon.set_texture"(t: i32) void; // write _texture
```

- A call to the getter emits no code; the variable is read where the value
  is used. A call to the setter is a `COPY`, or nothing at all when the
  value was just computed (the computation writes the variable).
- The variable has a real Udon type, so it can be exported to the Inspector,
  synced, initialized to `this`, and read by other behaviours.
- This is where handles that must outlive a function call are kept.
- A field whose `udonName` is the linear memory's variable name yields the
  memory `byte[]` itself (`docs/spec_linear_memory.md` §10).

`Boolean` fields read as a condition and are written from one; `Int32`,
`Int64`, `Single` and `Double` fields map to the matching WASM type; every
other type is a handle.

## 7. Worked example

```zig
extern "env" fn @"UnityEngineDebug.__Log__SystemString__SystemVoid"(ptr: [*]const u8, len: usize) void;

export fn _interact() void {
    const msg = "hi";
    @"UnityEngineDebug.__Log__SystemString__SystemVoid"(msg.ptr, msg.len);
}
```

```
PUSH, __utf8
PUSH, __G__memory
PUSH, __c_i32_65536          # ptr
PUSH, __c_i32_2              # len
PUSH, ___interact_T1__       # SystemString temporary
EXTERN, "SystemTextEncoding.__GetString__SystemByteArray_SystemInt32_SystemInt32__SystemString"
PUSH, ___interact_T1__
EXTERN, "UnityEngineDebug.__Log__SystemObject__SystemVoid"
```

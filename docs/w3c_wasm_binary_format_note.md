# WASM Core 1 Binary Format Specification

## Source and Status

This document is a restructured implementation-support document based on the W3C **WebAssembly Core Specification**, focused on the **binary format of WebAssembly Core 1.0 / MVP** for use in building a binary parser.

Original source:

* Title: WebAssembly Core Specification
* Status: W3C Recommendation, 5 December 2019
* Original: [https://www.w3.org/TR/wasm-core-1/](https://www.w3.org/TR/wasm-core-1/)
* This version: [https://www.w3.org/TR/2019/REC-wasm-core-1-20191205/](https://www.w3.org/TR/2019/REC-wasm-core-1-20191205/)
* W3C Document License: [https://www.w3.org/copyright/document-license-2023/](https://www.w3.org/copyright/document-license-2023/)

This document is **not itself the W3C specification**. It is a reorganized derivative intended to support implementation. The normative source is always the W3C specification above.

## Policy for Correspondence with W3C Section Numbers

Each section of this document corresponds primarily to the following sections of the W3C specification.

* Binary Format as a whole: W3C §5 Binary Format
* Custom / Name Section: W3C §7.4 Custom Sections, §7.4.1 Name Section
* Boundary matters related to validation: W3C §3 Validation and relevant Appendix constraints where necessary

A more detailed correspondence table is provided near the end of this document.

## Acknowledgements

This document relies on the structure, terminology, and definitions of the W3C WebAssembly Core Specification. In particular, it draws on the chapter structure for the binary format, the classification of types, values, instructions, and modules, and the definitions of custom sections and the name section.

## LICENSE / NOTICE

This document includes material copied from or derived from **WebAssembly Core Specification** ([https://www.w3.org/TR/wasm-core-1/](https://www.w3.org/TR/wasm-core-1/)).

Copyright © 2023 W3C®. This software or document includes material copied from or derived from WebAssembly Core Specification, [https://www.w3.org/TR/wasm-core-1/](https://www.w3.org/TR/wasm-core-1/).

W3C Document License (2023): [https://www.w3.org/copyright/document-license-2023/](https://www.w3.org/copyright/document-license-2023/)

This document is not a verbatim republication of the W3C document. It is a derivative explanatory document intended to support implementation. The original W3C source remains the only authoritative technical specification.

## Purpose

This document integrates, in one place, the information necessary to **syntactically read a `.wasm` file** with respect to the **WebAssembly Core 1.0 binary format**, including the dependent explanations needed to understand that syntax.

Its scope is the binary format of **Core 1.0 / MVP**. It does **not** include the behavior of the runtime, the execution semantics of instructions, linking, instantiation, or the meaning of traps.

Matters belonging to validation are kept to a minimum. The central aim is a **complete description of the binary syntax**.

## Scope

Included in this document:

* The binary structure of an entire module
* The representation of numbers, strings, vectors, types, and indices
* The structure of each section
* The representation of various immediates
* The binary encoding of instruction sequences and expressions
* The binary structure of custom sections and the name section
* Conditions under which a binary is malformed as a matter of binary format

Not included in this document:

* Runtime semantics
* Validation in full
* Import/export resolution
* Implementation strategy
* Recommendations for parser APIs, AST design, or internal representations
* Extensions from Core 2 or proposals

## Module as a Whole

A WebAssembly binary module has the following form.

```text
module := magic version section*
```

### magic

Fixed 4 bytes.

```text
00 61 73 6D
```

### version

For Core 1.0, fixed 4 bytes.

```text
01 00 00 00
```

If either the magic number or the version does not match, then the byte sequence is not a module under this specification.

## Basic Notation

### Byte

A `byte` is an 8-bit integer.

### Little-endian

Floating-point immediates are represented in little-endian order.

### Vectors

Any `vec(T)` consists of a `u32` element count followed by that many elements of type `T`.

```text
vec(T) := n:u32 T^n
```

Here `n` is the number of elements, not a byte length.

## Integer Encoding

The WebAssembly binary format represents many integers using **LEB128**.

## Unsigned Integer `uN`

A `uN` is encoded using unsigned LEB128.

* The value is split into 7-bit groups from the least significant side.
* The top bit of each byte is the continuation bit.
* If the continuation bit is 1, another byte follows.
* A byte with continuation bit 0 terminates the encoding.

A `uN` uses at most `ceil(N / 7)` bytes.

In the final byte, any unused bits beyond width `N` must be 0.

## Signed Integer `sN`

An `sN` is encoded using signed LEB128.

* The value is split into 7-bit groups from the least significant side.
* The continuation-bit rule is the same as for `uN`.
* The value is interpreted in two’s-complement form.

An `sN` also uses at most `ceil(N / 7)` bytes.

In the final byte, any unused bits beyond width `N` must be a sign extension consistent with the represented value.

## Conditions Under Which Integer Encoding Is Malformed

The following are malformed at the level of binary format.

* The continuation never terminates.
* The encoding exceeds the permitted number of bytes.
* The unused bits in the final byte violate the required rule.
* A field read as `u32` does not fit in `u32`.
* A field read as `s32` or `s64` violates the width rule for the corresponding bit width.

## Floating-Point Encoding

### `f32`

An `f32` is represented as a 4-byte little-endian IEEE 754 binary32 bit pattern.

### `f64`

An `f64` is represented as an 8-byte little-endian IEEE 754 binary64 bit pattern.

NaN payloads and canonicalization are not binary-format concerns.

## Names

A `name` is a vector of bytes whose contents must be valid UTF-8.

```text
name := vec(byte)
```

A `name` is not NUL-terminated. Its length is given by the leading `u32`.

A byte sequence that is not valid UTF-8 is malformed at the binary-format level.

## Value Types

In Core 1, `valtype` has the following four forms.

| byte   | type  |
| ------ | ----- |
| `0x7F` | `i32` |
| `0x7E` | `i64` |
| `0x7D` | `f32` |
| `0x7C` | `f64` |

Any other byte is malformed as a `valtype`.

## Result Types

A `resulttype` is a vector of `valtype`.

```text
resulttype := vec(valtype)
```

Validation in Core 1 restricts this to at most one result, but the binary encoding itself is described here.

## Function Types

A `functype` is encoded as follows.

```text
functype := 0x60 resulttype resulttype
```

The first `resulttype` is the parameter type sequence, and the second is the result type sequence.

If the leading byte is not `0x60`, the encoding is malformed.

## Limits

```text
limits :=
  0x00 min:u32
| 0x01 min:u32 max:u32
```

`0x00` denotes a lower bound only. `0x01` denotes both lower and upper bounds.

## Memory Types

```text
memtype := limits
```

## Element Type and Table Types

In Core 1, the only permitted `elemtype` is `funcref`.

```text
elemtype := 0x70
tabletype := elemtype limits
```

Any byte other than `0x70` is malformed.

## Global Types

```text
globaltype := valtype mut
mut := 0x00 | 0x01
```

| byte   | meaning   |
| ------ | --------- |
| `0x00` | immutable |
| `0x01` | mutable   |

## Indices

The following indices are all encoded as `u32`.

* `typeidx`
* `funcidx`
* `tableidx`
* `memidx`
* `globalidx`
* `localidx`
* `labelidx`

## Instruction Sequences and Expressions

## Expressions

An `expr` is an instruction sequence followed by the `end` opcode.

```text
expr := instr* end
end  := 0x0B
```

This form appears at least in the following places.

* Global initializer expressions
* Offset expressions in element segments
* Offset expressions in data segments
* Function bodies

## blocktype

In Core 1, `blocktype` is one of the following.

| encoding  | meaning       |
| --------- | ------------- |
| `0x40`    | no result     |
| `valtype` | single result |

## Structured Control Instructions

`block`, `loop`, and `if` contain nested instruction sequences.

### `block`

```text
block := 0x02 blocktype instr* 0x0B
```

### `loop`

```text
loop := 0x03 blocktype instr* 0x0B
```

### `if`

```text
if := 0x04 blocktype instr* (0x05 instr*)? 0x0B
```

Here `0x05` denotes `else`.

## Common Immediate Forms

### Memory Immediate

The immediate for load/store instructions is:

```text
memarg := align:u32 offset:u32
```

### `br_table`

```text
br_table := vec(labelidx) labelidx
```

The first part is the jump table; the second is the default target.

### `call_indirect`

In Core 1, `call_indirect` has the following form.

```text
0x11 typeidx 0x00
```

The trailing `0x00` is a reserved byte. Any other value is malformed.

### `memory.size` and `memory.grow`

In Core 1, both carry the reserved byte `0x00`.

```text
memory.size := 0x3F 0x00
memory.grow := 0x40 0x00
```

If this byte is not `0x00`, the encoding is malformed.

## Instructions

The following table lists the binary encodings of the opcodes included in Core 1 / MVP.

## Control Instructions

| opcode | instruction     | immediate                                                |
| ------ | --------------- | -------------------------------------------------------- |
| `0x00` | `unreachable`   | none                                                     |
| `0x01` | `nop`           | none                                                     |
| `0x02` | `block`         | `blocktype`, nested instr*, `0x0B`                       |
| `0x03` | `loop`          | `blocktype`, nested instr*, `0x0B`                       |
| `0x04` | `if`            | `blocktype`, then instr*, (`0x05`, else instr*)?, `0x0B` |
| `0x0C` | `br`            | `labelidx`                                               |
| `0x0D` | `br_if`         | `labelidx`                                               |
| `0x0E` | `br_table`      | `vec(labelidx)`, default `labelidx`                      |
| `0x0F` | `return`        | none                                                     |
| `0x10` | `call`          | `funcidx`                                                |
| `0x11` | `call_indirect` | `typeidx`, `0x00`                                        |

## Parametric Instructions

| opcode | instruction |
| ------ | ----------- |
| `0x1A` | `drop`      |
| `0x1B` | `select`    |

## Variable Instructions

| opcode | instruction  | immediate   |
| ------ | ------------ | ----------- |
| `0x20` | `local.get`  | `localidx`  |
| `0x21` | `local.set`  | `localidx`  |
| `0x22` | `local.tee`  | `localidx`  |
| `0x23` | `global.get` | `globalidx` |
| `0x24` | `global.set` | `globalidx` |

## Memory Instructions

All of the following load/store instructions take `memarg` as their immediate.

| opcode | instruction            |
| ------ | ---------------------- |
| `0x28` | `i32.load`             |
| `0x29` | `i64.load`             |
| `0x2A` | `f32.load`             |
| `0x2B` | `f64.load`             |
| `0x2C` | `i32.load8_s`          |
| `0x2D` | `i32.load8_u`          |
| `0x2E` | `i32.load16_s`         |
| `0x2F` | `i32.load16_u`         |
| `0x30` | `i64.load8_s`          |
| `0x31` | `i64.load8_u`          |
| `0x32` | `i64.load16_s`         |
| `0x33` | `i64.load16_u`         |
| `0x34` | `i64.load32_s`         |
| `0x35` | `i64.load32_u`         |
| `0x36` | `i32.store`            |
| `0x37` | `i64.store`            |
| `0x38` | `f32.store`            |
| `0x39` | `f64.store`            |
| `0x3A` | `i32.store8`           |
| `0x3B` | `i32.store16`          |
| `0x3C` | `i64.store8`           |
| `0x3D` | `i64.store16`          |
| `0x3E` | `i64.store32`          |
| `0x3F` | `memory.size` + `0x00` |
| `0x40` | `memory.grow` + `0x00` |

## Numeric Constant Instructions

| opcode | instruction | immediate |
| ------ | ----------- | --------- |
| `0x41` | `i32.const` | `i32`     |
| `0x42` | `i64.const` | `i64`     |
| `0x43` | `f32.const` | `f32`     |
| `0x44` | `f64.const` | `f64`     |

## Numeric Instructions

### `i32`

| opcode | instruction  |
| ------ | ------------ |
| `0x45` | `i32.eqz`    |
| `0x46` | `i32.eq`     |
| `0x47` | `i32.ne`     |
| `0x48` | `i32.lt_s`   |
| `0x49` | `i32.lt_u`   |
| `0x4A` | `i32.gt_s`   |
| `0x4B` | `i32.gt_u`   |
| `0x4C` | `i32.le_s`   |
| `0x4D` | `i32.le_u`   |
| `0x4E` | `i32.ge_s`   |
| `0x4F` | `i32.ge_u`   |
| `0x67` | `i32.clz`    |
| `0x68` | `i32.ctz`    |
| `0x69` | `i32.popcnt` |
| `0x6A` | `i32.add`    |
| `0x6B` | `i32.sub`    |
| `0x6C` | `i32.mul`    |
| `0x6D` | `i32.div_s`  |
| `0x6E` | `i32.div_u`  |
| `0x6F` | `i32.rem_s`  |
| `0x70` | `i32.rem_u`  |
| `0x71` | `i32.and`    |
| `0x72` | `i32.or`     |
| `0x73` | `i32.xor`    |
| `0x74` | `i32.shl`    |
| `0x75` | `i32.shr_s`  |
| `0x76` | `i32.shr_u`  |
| `0x77` | `i32.rotl`   |
| `0x78` | `i32.rotr`   |

### `i64`

| opcode | instruction  |
| ------ | ------------ |
| `0x50` | `i64.eqz`    |
| `0x51` | `i64.eq`     |
| `0x52` | `i64.ne`     |
| `0x53` | `i64.lt_s`   |
| `0x54` | `i64.lt_u`   |
| `0x55` | `i64.gt_s`   |
| `0x56` | `i64.gt_u`   |
| `0x57` | `i64.le_s`   |
| `0x58` | `i64.le_u`   |
| `0x59` | `i64.ge_s`   |
| `0x5A` | `i64.ge_u`   |
| `0x79` | `i64.clz`    |
| `0x7A` | `i64.ctz`    |
| `0x7B` | `i64.popcnt` |
| `0x7C` | `i64.add`    |
| `0x7D` | `i64.sub`    |
| `0x7E` | `i64.mul`    |
| `0x7F` | `i64.div_s`  |
| `0x80` | `i64.div_u`  |
| `0x81` | `i64.rem_s`  |
| `0x82` | `i64.rem_u`  |
| `0x83` | `i64.and`    |
| `0x84` | `i64.or`     |
| `0x85` | `i64.xor`    |
| `0x86` | `i64.shl`    |
| `0x87` | `i64.shr_s`  |
| `0x88` | `i64.shr_u`  |
| `0x89` | `i64.rotl`   |
| `0x8A` | `i64.rotr`   |

### `f32`

| opcode | instruction    |
| ------ | -------------- |
| `0x5B` | `f32.eq`       |
| `0x5C` | `f32.ne`       |
| `0x5D` | `f32.lt`       |
| `0x5E` | `f32.gt`       |
| `0x5F` | `f32.le`       |
| `0x60` | `f32.ge`       |
| `0x8B` | `f32.abs`      |
| `0x8C` | `f32.neg`      |
| `0x8D` | `f32.ceil`     |
| `0x8E` | `f32.floor`    |
| `0x8F` | `f32.trunc`    |
| `0x90` | `f32.nearest`  |
| `0x91` | `f32.sqrt`     |
| `0x92` | `f32.add`      |
| `0x93` | `f32.sub`      |
| `0x94` | `f32.mul`      |
| `0x95` | `f32.div`      |
| `0x96` | `f32.min`      |
| `0x97` | `f32.max`      |
| `0x98` | `f32.copysign` |

### `f64`

| opcode | instruction    |
| ------ | -------------- |
| `0x61` | `f64.eq`       |
| `0x62` | `f64.ne`       |
| `0x63` | `f64.lt`       |
| `0x64` | `f64.gt`       |
| `0x65` | `f64.le`       |
| `0x66` | `f64.ge`       |
| `0x99` | `f64.abs`      |
| `0x9A` | `f64.neg`      |
| `0x9B` | `f64.ceil`     |
| `0x9C` | `f64.floor`    |
| `0x9D` | `f64.trunc`    |
| `0x9E` | `f64.nearest`  |
| `0x9F` | `f64.sqrt`     |
| `0xA0` | `f64.add`      |
| `0xA1` | `f64.sub`      |
| `0xA2` | `f64.mul`      |
| `0xA3` | `f64.div`      |
| `0xA4` | `f64.min`      |
| `0xA5` | `f64.max`      |
| `0xA6` | `f64.copysign` |

### Conversion / Reinterpretation

| opcode | instruction           |
| ------ | --------------------- |
| `0xA7` | `i32.wrap_i64`        |
| `0xA8` | `i32.trunc_f32_s`     |
| `0xA9` | `i32.trunc_f32_u`     |
| `0xAA` | `i32.trunc_f64_s`     |
| `0xAB` | `i32.trunc_f64_u`     |
| `0xAC` | `i64.extend_i32_s`    |
| `0xAD` | `i64.extend_i32_u`    |
| `0xAE` | `i64.trunc_f32_s`     |
| `0xAF` | `i64.trunc_f32_u`     |
| `0xB0` | `i64.trunc_f64_s`     |
| `0xB1` | `i64.trunc_f64_u`     |
| `0xB2` | `f32.convert_i32_s`   |
| `0xB3` | `f32.convert_i32_u`   |
| `0xB4` | `f32.convert_i64_s`   |
| `0xB5` | `f32.convert_i64_u`   |
| `0xB6` | `f32.demote_f64`      |
| `0xB7` | `f64.convert_i32_s`   |
| `0xB8` | `f64.convert_i32_u`   |
| `0xB9` | `f64.convert_i64_s`   |
| `0xBA` | `f64.convert_i64_u`   |
| `0xBB` | `f64.promote_f32`     |
| `0xBC` | `i32.reinterpret_f32` |
| `0xBD` | `i64.reinterpret_f64` |
| `0xBE` | `f32.reinterpret_i32` |
| `0xBF` | `f64.reinterpret_i64` |

An unknown opcode is malformed at the binary-format level.

## Sections

Each section has the following form.

```text
section := id:byte size:u32 payload:size bytes
```

The internal structure of `payload` is determined by `id`.

## Section IDs

| id   | section  |
| ---- | -------- |
| `0`  | custom   |
| `1`  | type     |
| `2`  | import   |
| `3`  | function |
| `4`  | table    |
| `5`  | memory   |
| `6`  | global   |
| `7`  | export   |
| `8`  | start    |
| `9`  | element  |
| `10` | code     |
| `11` | data     |

Any other section ID is malformed.

## Section Order

Except for custom sections, known sections must appear in ascending order of the IDs above.

* A custom section may appear at any position.
* Repetition of a non-custom section is malformed.
* Violating the required order is malformed.

## Custom Section

```text
customsec := 0:size name bytes*
```

More precisely, the payload has the following form.

```text
custom_payload := name byte*
```

The leading `name` is the custom section name. The interpretation of the remaining bytes depends on that name.

Under this specification, the contents of a custom section may in general remain uninterpreted.

## Type Section

```text
typesec := section_1(vec(functype))
```

## Import Section

```text
importsec := section_2(vec(import))
import := module:name name:name importdesc
```

### importdesc

```text
importdesc :=
  0x00 typeidx
| 0x01 tabletype
| 0x02 memtype
| 0x03 globaltype
```

## Function Section

```text
funcsec := section_3(vec(typeidx))
```

This section contains only the type indices of functions that are not imported.

## Table Section

```text
tablesec := section_4(vec(tabletype))
```

## Memory Section

```text
memsec := section_5(vec(memtype))
```

## Global Section

```text
globalsec := section_6(vec(global))
global := globaltype expr
```

## Export Section

```text
exportsec := section_7(vec(export))
export := name exportdesc
```

### exportdesc

```text
exportdesc :=
  0x00 funcidx
| 0x01 tableidx
| 0x02 memidx
| 0x03 globalidx
```

## Start Section

```text
startsec := section_8(funcidx)
```

## Element Section

In Core 1, an element segment has the following form.

```text
elemsec := section_9(vec(elem))
elem := tableidx? offset:expr init:vec(funcidx)
```

In MVP binary encoding, it is encoded as follows.

```text
elem := 0x00 expr vec(funcidx)
```

Here the target table is implicitly table 0.

## Code Section

```text
codesec := section_10(vec(code))
code := size:u32 func
func := vec(local) expr
local := n:u32 valtype
```

`vec(local)` is the sequence of local declarations. Each entry means “introduce `n` locals of the same type.”

The `size` field of `code` is the byte length of the immediately following `func`.

If reading `func` does not consume exactly that many bytes, the binary is malformed.

## Data Section

In Core 1, a data segment has the following form.

```text
datasec := section_11(vec(data))
data := memidx? offset:expr init:vec(byte)
```

In MVP binary encoding, it is encoded as follows.

```text
data := 0x00 expr vec(byte)
```

Here the target memory is implicitly memory 0.

## Correspondence Between the Function Section and the Code Section

The number of type indices in the function section must equal the number of code entries in the code section.

If they do not match, the binary is malformed.

## Name Section

The `name` section is a kind of custom section, namely a custom section whose section name is the string `"name"`.

Its payload consists of a sequence of subsections.

```text
name_section := custom(name="name", subsection*)
subsection := id:byte size:u32 payload:size bytes
```

The following subsection IDs are defined in Core 1.

| id  | meaning        |
| --- | -------------- |
| `0` | module name    |
| `1` | function names |
| `2` | local names    |

Unknown subsection IDs may be skipped according to their `size`.

### name map

Function names and local names use a `name map`.

```text
namemap := vec(nameassoc)
nameassoc := idx:u32 name:name
```

### indirect name map

Local-variable names use a collection of per-function name maps.

```text
indirectnamemap := vec(indirectnameassoc)
indirectnameassoc := idx:u32 namemap
```

### module name subsection

```text
subsec_0 := name
```

### function name subsection

```text
subsec_1 := namemap
```

### local name subsection

```text
subsec_2 := indirectnamemap
```

Since the `name` section is a custom section, it is semantically optional. A module may still be valid even if it is absent.

## List of Conditions That Are Malformed at the Binary-Format Level

At minimum, the following are malformed at the binary-format level.

* The magic number does not match.
* The version does not match.
* The section ID is unknown.
* A non-custom section violates the required order.
* A non-custom section is repeated.
* A section size does not match the actual payload length.
* A LEB128 encoding violates its rules.
* A UTF-8 `name` is invalid.
* A `functype` tag is not `0x60`.
* A `valtype` is unknown.
* An `elemtype` is not `0x70`.
* `mut` is neither `0x00` nor `0x01`.
* The reserved byte of `call_indirect` is not `0x00`.
* The reserved byte of `memory.size` or `memory.grow` is not `0x00`.
* An unknown opcode appears.
* The termination rules of `if`, `block`, `loop`, or `expr` are violated.
* The declared size of a code entry does not match the actual function-body length.
* The number of entries in the function section and code section do not match.
* An element segment or data segment does not conform to the Core 1 form.

## Boundary Between Binary Format and Validation

The following generally belong, strictly speaking, to validation.

* Whether an index is within the defined range
* Whether `min <= max`
* Constraints on duplicate export names
* The type constraint on the start function
* Restrictions on instructions allowed in initializer expressions
* Constraints on the number of memories/tables
* Constraints on the number of results

Because the present document is centered on the binary parser, these may be separated into a distinct validation specification as needed.

## Reading Scope as Core 1

This document covers only the **Core 1 / MVP binary format**.

Accordingly, it does not include extensions such as the following.

* multi-value
* reference types
* bulk memory operations
* typed function references
* SIMD
* threads
* exceptions
* tail calls
* Other proposal-derived prefixed opcode groups

Handling binaries that include such extensions requires additional specifications for those features.

## How to Read This Specification

A useful dependency order for implementing a binary parser is as follows.

1. Module header
2. Integer / float / name / vec
3. Types and indices
4. Section framing
5. Instruction encoding and `expr`
6. Payload structure of each section
7. Custom sections / name section
8. Malformed conditions

Read in this order, the document is self-contained as a syntactic decoding specification for Core 1 binary modules, without dealing with runtime behavior.

## W3C Section Correspondence Table

This section indicates where the main parts of this document correspond to the W3C original.

| Section in this document                     | Primary correspondence                                                             | W3C link                                                                                                         |
| -------------------------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Module as a whole                            | §5.5 Modules, §5.5.2 Sections, §5.5.15 Modules                                     | [https://www.w3.org/TR/wasm-core-1/#binary-modules](https://www.w3.org/TR/wasm-core-1/#binary-modules)           |
| Basic notation / vectors                     | §5.1 Conventions, §5.1.3 Vectors                                                   | [https://www.w3.org/TR/wasm-core-1/#binary-format](https://www.w3.org/TR/wasm-core-1/#binary-format)             |
| Integer encoding                             | §5.2.2 Integers                                                                    | [https://www.w3.org/TR/wasm-core-1/#binary-values](https://www.w3.org/TR/wasm-core-1/#binary-values)             |
| Floating-point encoding                      | §5.2.3 Floating-Point                                                              | [https://www.w3.org/TR/wasm-core-1/#binary-values](https://www.w3.org/TR/wasm-core-1/#binary-values)             |
| Names                                        | §5.2.4 Names                                                                       | [https://www.w3.org/TR/wasm-core-1/#binary-values](https://www.w3.org/TR/wasm-core-1/#binary-values)             |
| Value types                                  | §5.3.1 Value Types                                                                 | [https://www.w3.org/TR/wasm-core-1/#binary-types](https://www.w3.org/TR/wasm-core-1/#binary-types)               |
| Result types                                 | §5.3.2 Result Types                                                                | [https://www.w3.org/TR/wasm-core-1/#binary-types](https://www.w3.org/TR/wasm-core-1/#binary-types)               |
| Function types                               | §5.3.3 Function Types                                                              | [https://www.w3.org/TR/wasm-core-1/#binary-types](https://www.w3.org/TR/wasm-core-1/#binary-types)               |
| limits                                       | §5.3.4 Limits                                                                      | [https://www.w3.org/TR/wasm-core-1/#binary-types](https://www.w3.org/TR/wasm-core-1/#binary-types)               |
| Memory types                                 | §5.3.5 Memory Types                                                                | [https://www.w3.org/TR/wasm-core-1/#binary-types](https://www.w3.org/TR/wasm-core-1/#binary-types)               |
| Table types                                  | §5.3.6 Table Types                                                                 | [https://www.w3.org/TR/wasm-core-1/#binary-types](https://www.w3.org/TR/wasm-core-1/#binary-types)               |
| Global types                                 | §5.3.7 Global Types                                                                | [https://www.w3.org/TR/wasm-core-1/#binary-types](https://www.w3.org/TR/wasm-core-1/#binary-types)               |
| Expressions                                  | §5.4.6 Expressions                                                                 | [https://www.w3.org/TR/wasm-core-1/#binary-instructions](https://www.w3.org/TR/wasm-core-1/#binary-instructions) |
| Control instructions                         | §5.4.1 Control Instructions                                                        | [https://www.w3.org/TR/wasm-core-1/#binary-instructions](https://www.w3.org/TR/wasm-core-1/#binary-instructions) |
| Parametric instructions                      | §5.4.2 Parametric Instructions                                                     | [https://www.w3.org/TR/wasm-core-1/#binary-instructions](https://www.w3.org/TR/wasm-core-1/#binary-instructions) |
| Variable instructions                        | §5.4.3 Variable Instructions                                                       | [https://www.w3.org/TR/wasm-core-1/#binary-instructions](https://www.w3.org/TR/wasm-core-1/#binary-instructions) |
| Memory instructions                          | §5.4.4 Memory Instructions                                                         | [https://www.w3.org/TR/wasm-core-1/#binary-instructions](https://www.w3.org/TR/wasm-core-1/#binary-instructions) |
| Numeric instructions                         | §5.4.5 Numeric Instructions                                                        | [https://www.w3.org/TR/wasm-core-1/#binary-instructions](https://www.w3.org/TR/wasm-core-1/#binary-instructions) |
| Indices                                      | §5.5.1 Indices                                                                     | [https://www.w3.org/TR/wasm-core-1/#binary-modules](https://www.w3.org/TR/wasm-core-1/#binary-modules)           |
| Sections in general                          | §5.5.2 Sections                                                                    | [https://www.w3.org/TR/wasm-core-1/#sections](https://www.w3.org/TR/wasm-core-1/#sections)                       |
| custom section                               | §5.5.3 Custom Section, Appendix §7.4 Custom Sections                               | [https://www.w3.org/TR/wasm-core-1/#custom-section](https://www.w3.org/TR/wasm-core-1/#custom-section)           |
| type section                                 | §5.5.4 Type Section                                                                | [https://www.w3.org/TR/wasm-core-1/#binary-modules](https://www.w3.org/TR/wasm-core-1/#binary-modules)           |
| import section                               | §5.5.5 Import Section                                                              | [https://www.w3.org/TR/wasm-core-1/#binary-modules](https://www.w3.org/TR/wasm-core-1/#binary-modules)           |
| function section                             | §5.5.6 Function Section                                                            | [https://www.w3.org/TR/wasm-core-1/#binary-modules](https://www.w3.org/TR/wasm-core-1/#binary-modules)           |
| table section                                | §5.5.7 Table Section                                                               | [https://www.w3.org/TR/wasm-core-1/#binary-modules](https://www.w3.org/TR/wasm-core-1/#binary-modules)           |
| memory section                               | §5.5.8 Memory Section                                                              | [https://www.w3.org/TR/wasm-core-1/#binary-modules](https://www.w3.org/TR/wasm-core-1/#binary-modules)           |
| global section                               | §5.5.9 Global Section                                                              | [https://www.w3.org/TR/wasm-core-1/#binary-modules](https://www.w3.org/TR/wasm-core-1/#binary-modules)           |
| export section                               | §5.5.10 Export Section                                                             | [https://www.w3.org/TR/wasm-core-1/#binary-modules](https://www.w3.org/TR/wasm-core-1/#binary-modules)           |
| start section                                | §5.5.11 Start Section                                                              | [https://www.w3.org/TR/wasm-core-1/#binary-modules](https://www.w3.org/TR/wasm-core-1/#binary-modules)           |
| element section                              | §5.5.12 Element Section                                                            | [https://www.w3.org/TR/wasm-core-1/#binary-modules](https://www.w3.org/TR/wasm-core-1/#binary-modules)           |
| code section                                 | §5.5.13 Code Section                                                               | [https://www.w3.org/TR/wasm-core-1/#binary-modules](https://www.w3.org/TR/wasm-core-1/#binary-modules)           |
| data section                                 | §5.5.14 Data Section                                                               | [https://www.w3.org/TR/wasm-core-1/#binary-modules](https://www.w3.org/TR/wasm-core-1/#binary-modules)           |
| name section                                 | Appendix §7.4.1 Name Section                                                       | [https://www.w3.org/TR/wasm-core-1/#name-section](https://www.w3.org/TR/wasm-core-1/#name-section)               |
| Malformed conditions and validation boundary | §3 Validation, Appendix §7.2 Implementation Limitations, §7.3 Validation Algorithm | [https://www.w3.org/TR/wasm-core-1/](https://www.w3.org/TR/wasm-core-1/)                                         |

## Notes

* In the W3C original, the main binary-format material is concentrated primarily in **§5.1–§5.5**.
* The `name section` is not placed in the main binary-modules section, but in the **Appendix section on custom sections**.
* Because this document is rearranged for parser implementation, some of its ordering differs from the order of presentation in the W3C original. The correspondence table indicates the principal source for each topic, not a strict one-to-one structural mapping.


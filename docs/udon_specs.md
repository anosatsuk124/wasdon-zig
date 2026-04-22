# Udon Assembly Specification

**Version**: 1.0
**Scope**: An assembly language for generating bytecode executed by the VRChat Udon VM
**Sources**: VRChat official documentation *"The Udon VM and Udon Assembly"* and *"【VRChat】Udon Assembly 詳解"* by akanevrc

---

## 1. Overview

### 1.1 Nature of the Udon VM

The Udon VM is a bytecode interpreter that executes compiled Udon programs. This specification defines the syntax and semantics of **Udon Assembly**, the textual form from which Udon VM bytecode is produced.

The Udon VM has the following characteristics:

1. The Udon VM is expected to run inside a .NET environment. It does not actually use reflection to invoke external functions, but its referencing style resembles reflection.
2. **It does not directly implement call/return instructions or subroutines.** An equivalent mechanism can be constructed manually by means of the `JUMP_INDIRECT` instruction.
3. Flow control is performed exclusively via the three instructions `JUMP`, `JUMP_INDIRECT`, and `JUMP_IF_FALSE`.
4. It can invoke C# functions where permitted (the `EXTERN` instruction).
5. **It has no local variables.** All variables are allocated as fields on the UdonBehaviour (i.e. on the Udon heap).
6. It has an integer stack, but this stack is effectively used as "extra parameters" for opcodes. It may be used to build a call/return mechanism, but because there are no local variables, recursive functions must be designed with great care.

### 1.2 Producing Bytecode

Udon Assembly is ordinarily emitted as the output of the Udon Graph or UdonSharp compilers, but it may also be written by hand via the **Udon Assembly Program Asset**. In Unity, this asset is created from the Project tab with `Create > VRChat > Udon > Udon Assembly Program Asset`.

---

## 2. Overall Program Structure

### 2.1 Sections

A Udon Assembly program consists of the following two sections.

| Section | Opening directive | Closing directive | Purpose |
| --- | --- | --- | --- |
| Data section | `.data_start` | `.data_end` | Declares variables and the attributes attached to them. |
| Code section | `.code_start` | `.code_end` | Declares instructions, labels, and the attributes attached to labels. |

Syntactic form:

```
.data_start
    # Data section contents
.data_end

.code_start
    # Code section contents
.code_end
```

### 2.2 Lexical Rules

- The assembly is interpreted **line by line**.
- Blank lines may be inserted freely.
- **Whitespace** within an instruction line may be inserted freely.
- Text from `#` to the end of a line is treated as a **comment**.

---

## 3. Udon Type Names

### 3.1 Definition

A "Udon type name" is the Udon Assembly–specific notation for a C# (.NET) type. Only types permitted by VRChat may be used.

### 3.2 Construction Rules

Given the fully qualified name of a C# type (for example `System.Int32[]`), the following rules are applied **in order**.

1. **Concatenate the namespace and type name with no intervening `.`.**
   Example: `System.String` → `SystemString`
2. **For a nested (inner) type, concatenate the enclosing type name and the inner type name with no intervening `+`.**
   Example: `VRC.SDKBase.VRCPlayerApi+TrackingData` → `VRCSDKBaseVRCPlayerApiTrackingData`
   Example: `Cinemachine.CinemachinePathBase+Appearance` → `CinemachineCinemachinePathBaseAppearance`
3. **For a generic type, append the Udon type name of each type argument (recursively constructed by these rules).**
   Example: `System.Collections.Generic.List<int>` → `SystemCollectionsGenericListSystemInt32`
4. **For an array type, do not write `[]`; append the suffix `Array` instead.**
   Example: `System.Int32[]` → `SystemInt32Array`
   Example: `System.DateTime[]` → `SystemDateTimeArray`

### 3.3 Notation in Variable Declarations

In a data-section variable declaration, the Udon type name produced by the rules above is prefixed with `%`.

### 3.4 Special Cases in External Function Signatures

- `VRCUdon.UdonBehaviour` appears inside extern signatures as **`VRCUdonCommonInterfacesIUdonEventReceiver`** (with the `Array` suffix appended if relevant).
- `VRCInstantiate` is an example of a "falsified" Udon type name (see §7.4).

---

## 4. The Data Section

### 4.1 Variable Declaration Syntax

```
<name>: %<UdonTypeName>, <initialValue>
```

Example:
```
message: %SystemString, "Hello, world!"
```

This line means:
- Symbol name: `message`
- Initial type: `System.String` (Udon type name `SystemString`)
- Initial value: the string literal `"Hello, world!"`

### 4.2 Storage on the Udon Heap

Variables declared in the data section are stored on the **Udon heap**. Despite the name, the Udon heap is in fact a flat array; each element holds a value together with its type. A position (index) in this array is called a **heap index**.

### 4.3 Meaning of the Declared Type

The type specified in a variable declaration is strictly the **initial type**. A variable's type may change at runtime. However, for public variables (declared with `.export`), changing the type at runtime is not recommended, as it would conflict with the Inspector-driven value.

### 4.4 Variable Name Rules

| Position | Permitted characters |
| --- | --- |
| First character | letters (`A–Z`, `a–z`), underscore (`_`) |
| Subsequent characters | letters, digits (`0–9`), underscore (`_`), square brackets (`[`, `]`), angle brackets (`<`, `>`) |

Valid examples: `x`, `X`, `abc123`, `_Number<0>`, `__this_is_a_variable[][]__>>>`
Invalid examples: `1` (leading digit), `222x` (leading digit), `$abc` (`$` is not permitted)

A variable name may coincide with a label name used in the code section; the two namespaces are distinguished by context.

**Note**: Udon has reserved variable names whose exact list is not fully documented. By convention, variable names are **prefixed with an underscore** to avoid collisions.

### 4.5 Initial-Value Literals

The following literal forms may be used as initial values.

| Literal | Meaning |
| --- | --- |
| `null` | A null reference (struct types are initialized to the type's `default` value instead). |
| `this` | A context-dependent special reference (see §4.6). |
| `true` / `false` | Boolean values (subject to the restriction in §4.7). |
| String literal `"..."` | `System.String` |
| Character literal | `System.Char` |
| Integer literal (decimal or hexadecimal) | A signed integer |
| Integer literal with trailing `u` | An unsigned integer (e.g. `0xFFFFFFFFu`) |
| Floating-point literal | A floating-point number |

**The assembler strictly validates which literal forms may be used for each type.**

### 4.6 Meaning of `this`

The meaning of `this` is determined by the declared type of the variable as follows.

| Declared type | What `this` refers to |
| --- | --- |
| `GameObject` | The `GameObject` that owns the UdonBehaviour |
| `Transform` | `gameObject.transform` of that `GameObject` |
| `UdonBehaviour`, `IUdonBehaviour`, `Object` | The UdonBehaviour itself |
| Any other type | **Error** |

### 4.7 Per-Type Literal Restrictions (Strict)

| Type | Permitted literals |
| --- | --- |
| `SystemSingle` (float), `SystemDouble` (double) | Numeric literal, or `null` |
| `SystemInt32`, `SystemUInt32` | Integer literal (with or without the `u` suffix), or `null` |
| `SystemString` | String literal, or `null` |
| Any other type (including `SystemObject`) | Only `this` or `null` |

**Important caveats:**
- **Floating-point literals are always read as `float`.** Even for a `SystemDouble` variable, the literal is interpreted at `float` precision.
- It is **not possible** to specify a non-null value for `SystemType` from Udon Assembly.
- The same limitation applies to `SystemInt64`, `SystemUInt64`, `SystemSByte`, `SystemByte`, `SystemInt16`, `SystemUInt16`, and `SystemBoolean`. In particular, **it is impossible to successfully specify `true` or `false` for a `SystemBoolean` variable** from Udon Assembly.
- These are limitations of the Udon Assembly assembler itself. They can only be circumvented by producing assembly via Udon Graph or UdonSharp.

### 4.8 Attributes

Two kinds of attribute may be attached to a variable. Attribute directives are written on a line separate from the declaration they modify.

#### 4.8.1 `.export`

```
.export <variableName>
```

Marks the variable as public. Public variables may be configured through the Unity Inspector.

#### 4.8.2 `.sync`

```
.sync <variableName>, <interpolationMode>
```

Marks the variable for network synchronization. This is equivalent to the "synced" checkbox in Udon Graph.

**Interpolation modes:**

| Mode | Meaning |
| --- | --- |
| `none` | No interpolation |
| `linear` | Linear interpolation |
| `smooth` | Smoothed interpolation |

**Note**: Not every interpolation mode is valid for every type. Refer to the VRChat networking documentation for details.

### 4.9 Complete Example

```
.data_start

    .export _name
    .sync   _name, none
    _name:  %SystemString, "Akane"

    _value: %SystemSingle, 12.345

.data_end
```

---

## 5. The Code Section

### 5.1 Constituents

The code section is composed of three kinds of element.

1. **Instructions** — an opcode with zero or one parameter.
2. **Labels** — names attached to instruction positions.
3. **Attributes** — currently only `.export`, used to publish a label as an event entry point.

### 5.2 Labels

```
<labelName>:
```

A label denotes the bytecode address of the instruction that immediately follows it. The naming rules match those for variable names (§4.4).

**Constraint:** Two or more labels must not point to the same bytecode position; doing so raises an `Address aliasing detected` error. This can be avoided by inserting a `NOP`.

### 5.3 The `.export` Attribute (Event Publication)

```
.export <labelName>
```

Applying `.export` to a code-section label publishes that label as an entry point for a UdonBehaviour event handler.

### 5.4 General Form of Instructions

An instruction is either an opcode name alone (zero parameters) or an opcode name followed by a comma and a single parameter.

```
<opcodeName>
<opcodeName>, <parameter>
```

A parameter may be any of the following.

- **An integer literal** — used directly (e.g. a raw address).
- **A symbol name** — a variable name or label name. The parameter takes the integer value associated with that symbol, i.e. the heap index (for variables) or the code address (for labels).
- **A string literal** — the assembler silently creates an anonymous (unnamed) variable initialized with that string, and the parameter takes the heap index of that anonymous variable.

---

## 6. Opcode Specifications

### 6.1 Opcode Table

| Instruction | Opcode # | Size (bytes) | Parameters |
| --- | --- | --- | --- |
| `NOP` | 0 | 4 | 0 |
| `PUSH` | 1 | 8 | 1 |
| `POP` | 2 | 4 | 0 |
| *(unused)* | 3 | — | — |
| `JUMP_IF_FALSE` | 4 | 8 | 1 |
| `JUMP` | 5 | 8 | 1 |
| `EXTERN` | 6 | 8 | 1 |
| `ANNOTATION` | 7 | 4 | 1 |
| `JUMP_INDIRECT` | 8 | 8 | 1 |
| `COPY` | 9 | 4 | 0 |

**Remarks:** Opcode number 3 is unused (reserved). Every instruction occupies either 4 or 8 bytes; consequently, when a code address is written in hexadecimal, its least-significant nibble is always one of `0`, `4`, `8`, or `C`.

### 6.2 Per-Instruction Specifications

#### 6.2.1 `NOP`

- **Opcode:** 0
- **Parameters:** 0
- **Size:** 4 bytes

Does nothing. Normally there is no reason to emit it, but it is useful as padding to resolve the `Address aliasing detected` error.

#### 6.2.2 `PUSH, <parameter>`

- **Opcode:** 1
- **Parameters:** 1
- **Size:** 8 bytes

Pushes the parameter (an integer) onto the top of the integer stack.

**Important:** Although the assembly notation can make it look as though a "value" is being pushed, **what is pushed is the heap index (an integer), not the heap value itself.**

For performance, the conventional pattern is to issue all required `PUSH` instructions immediately before a consuming instruction (`EXTERN`, `COPY`, or `JUMP_IF_FALSE`).

#### 6.2.3 `POP`

- **Opcode:** 2
- **Parameters:** 0
- **Size:** 4 bytes

Removes one value from the top of the integer stack. The removed value is discarded.

#### 6.2.4 `JUMP_IF_FALSE, <parameter>`

- **Opcode:** 4
- **Parameters:** 1
- **Size:** 8 bytes

Pops one heap index from the stack and reads a **`SystemBoolean`** from that heap slot.

- If the value is **`false`**: interprets the parameter as a bytecode address and jumps there.
- If the value is **`true`**: execution falls through to the next instruction.

**Note:** Only Boolean values are permitted at the popped slot.

#### 6.2.5 `JUMP, <parameter>`

- **Opcode:** 5
- **Parameters:** 1
- **Size:** 8 bytes

Unconditionally jumps to the bytecode address given by the parameter.

**Special address `0xFFFFFFFC`:** A `JUMP` to this address **terminates execution** (i.e. returns from the Udon program).

#### 6.2.6 `EXTERN, <parameter>`

- **Opcode:** 6
- **Parameters:** 1
- **Size:** 8 bytes

Invokes a C# method. This is the only instruction by which Udon performs any genuinely useful operation.

**Parameter semantics:**
- The parameter is a heap index. Initially the referenced heap slot contains the **extern name as a string**.
- On first execution of the extern, the Udon VM caches optimization information into that same heap slot. **The slot is therefore written to.**
- After caching, the slot is still an ordinary heap value and may be read or copied.

**Argument passing:**

Arguments are supplied by `PUSH` in order; **the first pushed value is the first argument**.

- **Normal (`in`) arguments:** the heap slot is read.
- **`ref` arguments:** the heap slot is both read and written.
- **`out` arguments:** the heap slot is written.

**The `this` argument:**
- If the method is non-static, the `this` argument is prepended as the **first** argument.
- If the method is static, no `this` is required.

**Return value:**
- If the method's return type is **not** `SystemVoid`, the return value is treated as an additional `out` argument at the **end** (i.e. the last `PUSH`ed variable receives the return value).
- If the return type is `SystemVoid`, no return-value push is needed.

**Canonical invocation pattern:**
```
PUSH, <instance>       # only for non-static methods
PUSH, <arg1>
PUSH, <arg2>
...
PUSH, <returnSlot>     # only if return type is not SystemVoid
EXTERN, "<externName>"
```

#### 6.2.7 `ANNOTATION, <parameter>`

- **Opcode:** 7
- **Parameters:** 1
- **Size:** 4 bytes

Effectively a "parameterized NOP"; the parameter is ignored and there is no runtime effect.

#### 6.2.8 `JUMP_INDIRECT, <parameter>`

- **Opcode:** 8
- **Parameters:** 1
- **Size:** 8 bytes

Interprets the parameter as a heap index, reads the referenced heap slot as a **`SystemUInt32`**, and jumps to that value as a bytecode address.

The typical use is to implement the return leg of a hand-rolled subroutine mechanism.

```
.data_start
    jumpVar: %SystemUInt32, 0x000001F0
.data_end
.code_start
    ...
    JUMP_INDIRECT, jumpVar   # jumps to address 0x000001F0
    ...
.code_end
```

#### 6.2.9 `COPY`

- **Opcode:** 9
- **Parameters:** 0
- **Size:** 4 bytes

Pops two heap indices from the stack. Let the **first popped value** be the one popped first (i.e. the one that was `PUSH`ed later — the destination), and the **second popped value** be the one popped second (i.e. the one that was `PUSH`ed earlier — the source).

**The value at the second popped heap index (the source) is copied into the slot at the first popped heap index (the destination).**

Single-operation example:
```
PUSH, a
PUSH, b
COPY
# Effect: b ← a  (the value of a is copied into b)
```

Multi-operation example:
```
PUSH, a
PUSH, b
PUSH, c
COPY   # c ← b
PUSH, d
COPY   # d ← a
```

---

## 7. External-Function (EXTERN) Signatures

### 7.1 Basic Form

An extern name takes the form:

```
<UdonTypeName>.<signature>
```

Example:
```
SystemDateTimeOffset.__TryParseExact__SystemString_SystemStringArray_SystemIFormatProvider_SystemGlobalizationDateTimeStyles_SystemDateTimeOffsetRef__SystemBoolean
```

This corresponds to the C# method:
```csharp
System.DateTimeOffset.TryParseExact(
    string, string[], System.IFormatProvider, System.Globalization.DateTimeStyles,
    out System.DateTimeOffset
) : bool
```

### 7.2 Structure of the Signature String

The signature component is constructed in the following order.

```
__<methodName>__<argTypeList>__<returnType>
```

1. **Leading `__`.**
2. **Method name** (for constructors this is `ctor`).
3. **`__`.**
4. **Argument-type list.** Each argument is written as its **Udon type name**.
   - Multiple arguments are separated by a single underscore `_`.
   - If the method takes no arguments, this field is `SystemVoid`.
   - **A `ref` or `out` parameter is marked by appending the suffix `Ref` to its Udon type name** (e.g. `SystemDateTimeOffsetRef`). The distinction between `ref` and `out` is not encoded.
5. **`__`.**
6. **Return-type's Udon type name.** For a method that returns nothing (void), this is `SystemVoid`.

### 7.3 Static vs. Instance Methods

- **Whether a method is static or non-static cannot be determined from the signature string alone.**
- For a non-static method, the `this` parameter **does not appear** in the argument-type list of the signature. It is supplied implicitly as the first `PUSH`ed argument at call time.

### 7.4 Special Cases

- **Generic methods:** Type parameters appear in the signature as "Udon type names" such as `T`. In addition, they have invisible extra `SystemType` parameters.
- **`VRCUdon.UdonBehaviour`:** In extern signatures this is replaced by `VRCUdonCommonInterfacesIUdonEventReceiver` (with the `Array` suffix when applicable).
- **`VRCInstantiate`:** The sole known example of a "falsified" Udon type name.

### 7.5 Absence of a Complete Reference

- **There is no official, complete reference of externs.**
- Useful sources:
  - The UdonSharp documentation's API reference for VRChat methods.
  - The UdonSharp **Class Exposure Tree**, which can be used to discover what is available.
- To obtain the exact extern name for a given method, inspection via Udon Graph may be required.

---

## 8. Events

### 8.1 Defining Events

Applying `.export` to a code-section label registers that label as a UdonBehaviour event handler.

### 8.2 Standard Events

- Standard event labels **begin with an underscore `_`**.
- The conversion rule from the source event name is: lowercase the first letter and prepend `_`.
  - `Start` → `_start`
  - `Update` → `_update`
  - `OnPlayerJoined` → `_onPlayerJoined`
  - `OnEnable` → `_onEnable`
- The parameters of a standard event are passed via **dedicated non-public variables** that the author must declare. The names of these variables are most easily discovered through Udon Graph.

### 8.3 Initial Event-Execution Order

1. **`_onEnable` runs first.**
2. Immediately afterwards, **`_start` runs.**
3. No other events run between `_onEnable` and `_start`.
4. This initial execution always precedes any other event. Any attempt to bypass it is **ignored**.

Refer to the VRChat "Event Execution Order" documentation for further details.

### 8.4 Custom Events

- Custom event names **must not start with `_`** (to distinguish them from standard events).
- Custom events **take no parameters** beyond any author-defined passing mechanism.

### 8.5 Example

```
.code_start
    .export _start
    _start:
        ...
        JUMP, 0xFFFFFFFC

    .export _update
    _update:
        ...
        JUMP, 0xFFFFFFFC
.code_end
```

---

## 9. Bytecode Address Space

### 9.1 Code Addresses

- The first instruction of the code section is at address **`0`**.
- Each instruction occupies its instruction size (4 or 8 bytes); subsequent addresses advance by that amount.
- Example: if a `PUSH` (8 bytes) sits at `0x00`, the next instruction is at `0x08`.
- Because instruction sizes are always 4 or 8, the least-significant nibble of any valid instruction address is always one of `0`, `4`, `8`, `C`.

### 9.2 Special Addresses

| Address | Meaning |
| --- | --- |
| `0xFFFFFFFC` | Terminates execution (`JUMP, 0xFFFFFFFC` returns from the Udon program). |

### 9.3 Heap Addresses

- Heap indices are assigned as a flat integer index based on the order of variables in the data section (including any anonymous variables generated by the assembler).
- Symbol references are resolved to heap indices at assembly time.

---

## 10. Automatic Generation of Anonymous Variables

When a **string literal** is supplied directly as a parameter to an instruction such as `EXTERN` or `PUSH`, the assembler implicitly generates an **anonymous (unnamed) variable** in the data section, initialized with that string, and substitutes the heap index of that variable as the instruction's parameter.

The most common occurrence of this behavior is the extern-name argument to `EXTERN`.

---

## 11. Example Programs

### 11.1 Printing a Message from the `_start` Event

```
.data_start
    message: %SystemString, "Hello, world!"
.data_end

.code_start
    .export _start
    _start:
        PUSH, message
        EXTERN, "UnityEngineDebug.__Log__SystemObject__SystemVoid"
        JUMP, 0xFFFFFFFC
.code_end
```

### 11.2 Conditional Branching (if / else)

```
.code_start
    .export _start
    _start:
        PUSH, condVar            # condVar: %SystemBoolean
        JUMP_IF_FALSE, elseLabel
        # then branch
        ...
        JUMP, endLabel
    elseLabel:
        # else branch
        ...
    endLabel:
        JUMP, 0xFFFFFFFC
.code_end
```

### 11.3 Calling a Method and Receiving Its Return Value

```
# Invoking the non-static method  someInstance.Foo(arg1, arg2) : int
PUSH, someInstance
PUSH, arg1
PUSH, arg2
PUSH, retVar
EXTERN, "SomeType.__Foo__SystemInt32_SystemInt32__SystemInt32"
```

---

## 12. Summary of Constraints and Cautions

1. **No local variables exist.** Every variable is a field on the heap. Recursive functions must be designed with this in mind.
2. **No call/return instructions exist.** An equivalent must be built by hand from `JUMP_INDIRECT` and heap variables.
3. **`Address aliasing detected` error:** two or more labels pointing at the same code position are forbidden.
4. **Assembler-level limitation:** non-null initial values for `SystemType`, `SystemInt64`, `SystemUInt64`, `SystemSByte`, `SystemByte`, `SystemInt16`, `SystemUInt16`, and `SystemBoolean` cannot be specified. In particular, **assigning `true` or `false` directly to a `SystemBoolean` variable is not possible.** These limitations can only be worked around by producing assembly through Udon Graph or UdonSharp.
5. **Floating-point literals are always read as `float`.** Even `SystemDouble` initial values are therefore limited to `float` precision.
6. **The format of extern signatures has exceptions and irregularities.** Tooling that relies entirely on parsing signatures is discouraged.
7. **If a syntax error exists in the assembly while the asset is selected in the Inspector, the error message is logged every frame.** The recommended workflow is to edit in an external text editor and paste the completed code; closing the Inspector stops the error stream.
8. **The heap slot referenced by an `EXTERN` parameter is overwritten by optimization cache data on first execution.** It remains a usable heap value afterwards, but the original extern-name string cannot be recovered from it.

---

## Appendix A: Opcode Quick Reference

| # | Instruction | Size | Effect |
| --- | --- | --- | --- |
| 0 | `NOP` | 4 | Nothing |
| 1 | `PUSH, x` | 8 | Push `x` onto the stack |
| 2 | `POP` | 4 | Discard one element from the stack |
| 3 | *(unused)* | — | — |
| 4 | `JUMP_IF_FALSE, addr` | 8 | Conditional jump (Boolean == false) |
| 5 | `JUMP, addr` | 8 | Unconditional jump |
| 6 | `EXTERN, name` | 8 | External function call |
| 7 | `ANNOTATION, x` | 4 | No effect (parameter ignored) |
| 8 | `JUMP_INDIRECT, var` | 8 | Indirect jump (uses `var`'s UInt32 value as the address) |
| 9 | `COPY` | 4 | Heap-value copy |

## Appendix B: Glossary

- **Udon VM** — The virtual machine that executes Udon bytecode.
- **Udon Assembly** — The textual assembly language corresponding to the bytecode executed by the Udon VM.
- **Udon heap** — The flat array that stores variable values (despite its name, it is not a heap-structured allocator).
- **Heap index** — An integer index identifying a variable's position within the Udon heap.
- **Code address** — A 32-bit value identifying an instruction's position within the bytecode.
- **Udon type name** — The naming convention used to express C# types inside Udon Assembly.
- **Extern** — A reference to a C# method, invoked via the `EXTERN` instruction.

---

*This specification reorganizes the information contained in the sources listed above into a single coherent document. As noted on the VRChat official documentation ("This page was written by a member of the VRChat community. Thank you for your contribution!"), part of the information is outside the scope of any official guarantee.*

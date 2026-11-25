# `__udon_meta` Content Design

## Purpose

`__udon_meta` is a static metadata blob that is independent of the computational semantics of the Wasm binary itself, and is intended to be read by a `WASM -> WAT -> UdonAssembly` translator.

The metadata is mainly intended to express the following three kinds of information:

* Which Udon variables the program shares with the Inspector, other behaviours and the network
* Which Udon event labels Wasm-side functions should correspond to
* Translator options

---

## Basic Policy

* `__udon_meta` is a conceptual metadata body; its contents are UTF-8 JSON
* Concretely, the body is placed as a static byte sequence inside a Wasm data segment
* Its location is surfaced to the translator by exporting a pointer/length pair (`__udon_meta_ptr`, `__udon_meta_len`)
* If the translator finds the metadata, it decodes the bytes as UTF-8 JSON and uses them
* If it is not found, lowering proceeds with default behavior
* It is not intended to be read by the Wasm side at runtime
* It is treated strictly as conversion-time metadata

Wasm export kinds are limited to `func`, `global`, `memory`, and `table`. Byte
arrays themselves cannot be exported, so the canonical representation is:

* The JSON lives in a `data` segment inside the module's linear memory
* Two `global` exports (or two `func` exports returning the same values) describe where in memory the JSON lives:
  * `__udon_meta_ptr` — the byte offset of the first byte of the JSON
  * `__udon_meta_len` — the length in bytes of the JSON
* The translator reads these two exports, slices the data segment, and decodes the slice as UTF-8

This is the only supported form. Raw-symbol resolution (e.g. looking up a
static symbol literally named `__udon_meta`) is not supported — producers must
emit the `__udon_meta_ptr` / `__udon_meta_len` export pair.

---

## Placement in Wasm

### WAT example

```wat
(module
  (memory (export "memory") 1)

  ;; Metadata location surfaced to the translator
  (global (export "__udon_meta_ptr") i32 (i32.const 1024))
  (global (export "__udon_meta_len") i32 (i32.const 285))

  ;; Ordinary Wasm-side state referenced by the metadata
  (global $player_name (mut i32) (i32.const 0))
  (export "player_name" (global $player_name))

  (func $on_start nop)
  (export "on_start" (func $on_start))

  ;; The JSON body lives in a data segment at offset 1024
  (data (i32.const 1024)
    "{\22version\22:1,\22fields\22:{...},\22functions\22:{...}}")
)
```

### Zig example

```zig
const udon_meta_json =
    \\{
    \\  "version": 1,
    \\  "fields": {
    \\    "playerName": {
    \\      "source": { "kind": "global", "name": "player_name" },
    \\      "udonName": "_playerName",
    \\      "type": "string",
    \\      "export": true,
    \\      "sync": { "enabled": true, "mode": "none" }
    \\    }
    \\  },
    \\  "functions": {
    \\    "start": {
    \\      "source": { "kind": "export", "name": "on_start" },
    \\      "label": "_start",
    \\      "export": true,
    \\      "event": "Start"
    \\    }
    \\  }
    \\}
;

export fn __udon_meta_ptr() [*]const u8 {
    return udon_meta_json.ptr;
}

export fn __udon_meta_len() u32 {
    return @intCast(udon_meta_json.len);
}

export var player_name: i32 = 0;
export fn on_start() void {}
```

Either form (exported `global` or exported `func` returning the same values) is
acceptable; the translator must tolerate both.

---

## Top-Level Structure

```json
{
  "version": 1,
  "behaviour": {},
  "fields": {},
  "functions": {},
  "imports": {},
  "options": {}
}
```

`imports` is for a module built for another host: it binds imports that
are not Udon externs to a console, a clock, a panic, a constant answer or
a halt. Its keys, values and semantics are in
`docs/spec_host_import_conversion.md` §8.

---

## `fields`

`fields` declares Udon variables that the WASM program shares with the
outside world: values set in the Inspector, values other behaviours read,
synced values, and references to Unity objects.

```json
{
  "fields": {
    "<field-key>": {
      "source": { "kind": "global | import | symbol", "name": "…" },
      "udonName": "string",
      "type": "bool | int | uint | float | string | object | gameobject | transform | udonBehaviour | <Udon type name>",
      "export": false,
      "sync": { "enabled": false, "mode": "none | linear | smooth" },
      "default": null,
      "comment": "string"
    }
  }
}
```

### `source`

Where the field's value lives on the WASM side. There are three kinds.

#### `global` — a WASM global

```json
{ "kind": "global", "name": "score" }
```

`name` is the export name of a WASM global. The global *is* the Udon
variable: `global.get` / `global.set` read and write it directly. The
field's type must match the global's value type (`int` for `i32`, `float`
for `f32`).

Compilers rarely emit mutable globals for program state (see `symbol`);
this kind is mostly for hand-written WAT.

#### `import` — an Udon variable accessed through imports

```json
{ "kind": "import", "module": "env", "name": "udon.texture", "setter": "udon.set_texture" }
```

The variable lives in the Udon heap with the field's `type`. `name` is a
function import `() -> T` that reads it; the optional `setter` is a function
import `(T) -> ()` that writes it (`module` applies to both and may be
omitted). Calls to them are not externs: a read costs nothing, a write is a
`COPY` or less (`docs/spec_host_import_conversion.md` §6).

`T` is the matching WASM type for `int` / `float` (and `SystemInt64`,
`SystemDouble`), `i32` holding 0 or 1 for `bool`, and an opaque `i32`
handle for every other type. This is the general mechanism: it works for
any Udon type, in both directions, at any time.

If `name` matches an imported WASM *global* instead of a function, the
field describes that global.

#### `symbol` — a variable in linear memory

```json
{ "kind": "symbol", "name": "radius" }
```

`name` is an exported global holding the **address** of a variable in
linear memory — what `export var radius: f32` (Zig) or an exported `static`
(Rust, C) produces. The field is an **input**: the init routine copies the
field's value (as set in the Inspector, or its `default`) into memory once,
after the data segments and after the module's start function. Later
changes on either side are not propagated; use an `import` field for state
that must stay visible.

`type` must be `int`, `float` or `string`. An `int` or `float` is a 4-byte
variable. A `string` is a character buffer: the text is written at the
address as UTF-8, followed by a NUL — a C string. The translator does not
know the buffer's size; the text must fit. This is how a program that
expects its host to write a configuration string into its memory gets one
(`examples/linux`: the kernel's command line).

### `udonName`

Name of the Udon variable. Defaults to the field key (for `global`
fields, to `__G__<name>`).

### `type`

The Udon type of the variable: one of the aliases above, or any Udon type
name from the node list (`UnityEngineTexture2D`, `SystemByteArray`,
`VRCSDKBaseVRCPlayerApi`, `UnityEngineTransformArray`, …).

### `export`

If `true`, `.export <name>` is attached: the variable appears in the
Inspector and is reachable with `GetProgramVariable`.

### `sync`

Emits `.sync <name>, <mode>`. `enabled = true` without `mode` is an error.

### `default`

Initial value. A number for `int` / `uint` / `float`; a string for
`string`; the string `"this"` for the types Udon can resolve it for —
`UnityEngineGameObject`, `UnityEngineTransform`, `VRCUdonUdonBehaviour` and
`UnityEngineObject` (`docs/udon_specs.md` §4.6); `null`. Udon Assembly cannot
initialize any other type to anything but `null`
(`docs/udon_specs.md` §4.7), and the translator rejects defaults it cannot
express.

### `comment`

A human-facing note. No effect.

---

## `functions`

`functions` binds exported WASM functions to Udon event labels.

```json
{
  "functions": {
    "<function-key>": {
      "source": { "kind": "export", "name": "on_start" },
      "label": "_start",
      "export": true,
      "event": "Start | Update | Interact | custom",
      "comment": "string"
    }
  }
}
```

- `source.name` is the WASM export name. A name the module does not export
  is handled per `options.unknownFunctionPolicy`.
- `label` is the Udon label: `_start`, `_update`, `_interact`,
  `_onPlayerJoined`, … for standard events (any event in the node list), or
  a name not starting with `_` for a custom event. If omitted, `event`
  supplies it (`Start` → `_start`, `Update` → `_update`, `Interact` →
  `_interact`).
- The function must take no parameters. Standard events deliver their
  arguments in dedicated variables; declare those as `import` fields (for
  example `onPlayerJoinedPlayer` of type `VRCSDKBaseVRCPlayerApi`).

**Without a `functions` section**, every exported function with no
parameters and no results whose name is a valid Udon label becomes an event
of that name: `export fn _start()`, `export fn _update()`,
`export fn Reset()` need no metadata at all.

Functions that no event reaches are not translated.

---

## `behaviour`

`behaviour` represents the lowering policy for the UdonBehaviour as a whole.

```json
{
  "behaviour": {
    "syncMode": "none | manual | continuous",
    "comment": "string"
  }
}
```

### `syncMode`

The default synchronization mode for the behaviour as a whole.

This is not treated as a direct `.sync` line in Udon Assembly itself. Instead, it is treated as metadata for the translator or for reflected configuration of the generated component.

---

## `options`

```json
{
  "options": {
    "strict": false,
    "unknownFieldPolicy": "ignore | warn | error",
    "unknownFunctionPolicy": "ignore | warn | error",
    "recursion": "stack | disabled",
    "callStackSize": 1024,
    "memory": { "initialPages": 1, "maxPages": 256, "udonName": "_memory" }
  }
}
```

- `strict` — treat an import that is not in the Udon node list, and a field
  or function whose source does not exist, as an error instead of a warning.
- `unknownFieldPolicy`, `unknownFunctionPolicy` — what to do when a field's
  or function's `source` names something the module does not have. Default
  `warn`.
- `recursion` — `stack` (default): functions on a call-graph cycle save
  their frame around calls that may re-enter them. `disabled`: no saving;
  correct only if nothing is ever re-entered
  (`docs/spec_call_return_conversion.md` §6).
- `callStackSize` — the maximum depth of active re-entrant calls (default
  1024); see `docs/spec_call_return_conversion.md` §6.
- `recursionUnroll` — how many levels of a small self-recursive function
  get slots of their own and save no frame (default 64; 0 turns it off).
  More levels are more code; see `docs/spec_call_return_conversion.md` §6.
- `memory` — see below.

### `options.memory`

All fields are optional (`docs/spec_linear_memory.md` §9).

- `initialPages` — 64 KiB pages allocated at startup; never less than the
  module's declared minimum or than its data segments need.
- `maxPages` — bound for `memory.grow`. Falls back to the module's declared
  maximum, then to 1024.
- `udonName` — name of the memory variable (default `__G__memory`); the
  size variable is `<udonName>_size_pages`.

---

## Complete Example

```json
{
  "version": 1,
  "behaviour": {
    "syncMode": "manual",
    "comment": "Default behaviour sync mode"
  },
  "fields": {
    "playerName": {
      "source": {
        "kind": "global",
        "name": "player_name"
      },
      "udonName": "_playerName",
      "type": "string",
      "export": true,
      "sync": {
        "enabled": true,
        "mode": "none"
      },
      "default": "Akane"
    },
    "doorOpen": {
      "source": {
        "kind": "import",
        "name": "udon.door_open",
        "setter": "udon.set_door_open"
      },
      "udonName": "_doorOpen",
      "type": "bool",
      "export": false,
      "sync": {
        "enabled": true,
        "mode": "none"
      },
      "default": null
    },
    "ownerId": {
      "source": {
        "kind": "global",
        "name": "owner_id"
      },
      "udonName": "_ownerId",
      "type": "int",
      "export": false,
      "sync": {
        "enabled": false,
        "mode": "none"
      }
    }
  },
  "functions": {
    "start": {
      "source": {
        "kind": "export",
        "name": "on_start"
      },
      "label": "_start",
      "export": true,
      "event": "Start"
    },
    "interact": {
      "source": {
        "kind": "export",
        "name": "on_interact"
      },
      "label": "_interact",
      "export": true,
      "event": "Interact"
    },
    "customReset": {
      "source": {
        "kind": "export",
        "name": "reset_state"
      },
      "label": "ResetState",
      "export": true,
      "event": "custom"
    }
  },
  "options": {
    "strict": true,
    "unknownFieldPolicy": "warn",
    "unknownFunctionPolicy": "warn",
    "memory": {
      "initialPages": 1,
      "maxPages": 16,
      "udonName": "_memory"
    }
  }
}
```

---

## Conversion Rules

1. **Find the metadata.** Evaluate the exports `__udon_meta_ptr` and
   `__udon_meta_len` (constant globals or constant nullary functions),
   slice the data segment that contains the range, and parse it as UTF-8
   JSON. If either export is missing the module has no metadata and
   defaults apply. Malformed JSON, an unsupported `version`, or a range
   outside a single data segment is an error.
2. **Fields.** Declare one Udon variable per field as described above, with
   its `.export` / `.sync` attributes and initial value.
3. **Functions.** Emit an exported label per binding; translate only what
   those labels (and the WASM start function) reach.
4. **`behaviour.syncMode`** has no Udon Assembly representation; it is
   parsed and otherwise ignored. Set the sync mode on the UdonBehaviour
   component.
5. **Options** steer the translator as listed above.

---

## Minimal Implementation Example

```json
{
  "version": 1,
  "fields": {
    "playerName": {
      "source": {
        "kind": "global",
        "name": "player_name"
      },
      "udonName": "_playerName",
      "type": "string",
      "export": true,
      "sync": {
        "enabled": true,
        "mode": "none"
      }
    }
  },
  "functions": {
    "start": {
      "source": {
        "kind": "export",
        "name": "on_start"
      },
      "label": "_start",
      "export": true,
      "event": "Start"
    }
  }
}
```


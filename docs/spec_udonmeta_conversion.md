# `__udon_meta` Content Design

## Purpose

`__udon_meta` is a static metadata blob that is independent of the computational semantics of the Wasm binary itself, and is intended to be read by a `WASM -> WAT -> UdonAssembly` translator.

The metadata is mainly intended to express the following three kinds of information:

* How state on the Wasm side should be treated as data-section variables on the Udon side
* Which Udon event labels Wasm-side functions should correspond to
* What synchronization policy and conversion options should apply to the UdonBehaviour as a whole

---

## Basic Policy

* `__udon_meta` is a conceptual metadata body; its contents are UTF-8 JSON
* Concretely, the body is placed as a static byte sequence inside a Wasm data segment
* Its location is surfaced to the translator by exporting a pointer/length pair (`__udon_meta_ptr`, `__udon_meta_len`); alternatively, the translator may resolve it by the symbol name `__udon_meta` when the producer toolchain preserves that symbol reliably
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

The symbol-based alternative (exposing a named static symbol `__udon_meta`) is
permitted but fragile, because static symbol preservation is toolchain-dependent.
When in doubt, prefer the `__udon_meta_ptr` / `__udon_meta_len` pair.

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
  "options": {}
}
```

---

## `fields`

`fields` describes attributes for variables that will ultimately be placed in the Udon data section.

```json
{
  "fields": {
    "<field-key>": {
      "source": {
        "kind": "global | symbol"
      },
      "udonName": "string",
      "type": "bool | int | uint | float | string | object",
      "export": false,
      "sync": {
        "enabled": false,
        "mode": "none | linear | smooth"
      },
      "default": null,
      "comment": "string"
    }
  }
}
```

### `source`

Indicates which Wasm-side state a field is generated from.

#### When referring to a global

```json
{
  "kind": "global",
  "name": "score"
}
```

#### When referring to a symbol name

```json
{
  "kind": "symbol",
  "name": "__state_owner_id"
}
```

### `udonName`

The name of the generated Udon variable. If omitted, the key name is used.

### `type`

A hint for the initial type emitted into the Udon data section.

### `export`

If `true`, `.export <name>` is attached to that variable.

### `sync`

Corresponds to `.sync <variableName>, <interpolationMode>` in Udon.

* If `enabled = false`, no `.sync` is emitted
* `mode = none | linear | smooth`

If `enabled = true` but `mode` is missing, this should be treated as an error.

### `default`

An initial-value hint. It is used as-is only when it fits within Udon Assembly literal constraints.

### `comment`

A human-facing note. It has no effect on conversion semantics.

---

## `functions`

`functions` provides label/export information in the Udon code section for Wasm-side functions.

```json
{
  "functions": {
    "<function-key>": {
      "source": {
        "kind": "export | symbol | name"
      },
      "label": "string",
      "export": true,
      "event": "Start | Update | Interact | custom",
      "comment": "string"
    }
  }
}
```

### `source`

Specifies which Wasm function is being referred to.

#### Referencing by export name

```json
{
  "kind": "export",
  "name": "on_start"
}
```

#### Referencing by symbol name

```json
{
  "kind": "symbol",
  "name": "__wasm_entry_interact"
}
```

#### Referencing by debug/name-based identifier

```json
{
  "kind": "name",
  "name": "interact"
}
```

### `label`

The label name to generate in the Udon code section.

Examples:

* `_start`
* `_update`
* `_interact`
* `CustomEventFoo`

### `export`

If `true`, `.export <label>` is attached to that label.

### `event`

A logical event name. It may be used as auxiliary information when `label` is omitted.

Default mapping examples:

* `Start` -> `_start`
* `Update` -> `_update`
* `Interact` -> `_interact`
* `custom` -> explicit `label` is required

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

`options` contains auxiliary settings related to the behavior of the translator itself.

```json
{
  "options": {
    "strict": true,
    "unknownFieldPolicy": "ignore | warn | error",
    "unknownFunctionPolicy": "ignore | warn | error",
    "memory": {
      "initialPages": 1,
      "maxPages": 256,
      "udonName": "_memory"
    }
  }
}
```

### `options.memory`

Overrides for how WASM linear memory is lowered. See `spec_linear_memory.md` for the underlying model (a two-level chunked array with runtime `memory.grow` support).

All fields are optional.

- `initialPages` — number of 64 KiB pages committed at `_onEnable`. If omitted, the WASM module's declared `initial` is used.
- `maxPages` — upper bound used to size the outer `SystemObjectArray` and to gate `memory.grow`. Resolution order: this field, then the WASM module's declared `max`, then a default of `256` when the module has no `max` and `options.strict` is not `true`. With `options.strict = true` and no `max` anywhere, the translator raises an error. `initialPages > maxPages` is always an error.
- `udonName` — overrides the Udon variable name of the outer array (default `__G__memory`). Companion scalars `__G__memory_size_pages` and `__G__memory_max_pages` follow the same prefix rule and are renamed in lockstep.

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
        "kind": "symbol",
        "name": "__state_door_open"
      },
      "udonName": "_doorOpen",
      "type": "bool",
      "export": false,
      "sync": {
        "enabled": true,
        "mode": "smooth"
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
        "kind": "symbol",
        "name": "__entry_reset"
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

### 1. Find `__udon_meta`

* Look for the exports `__udon_meta_ptr` and `__udon_meta_len` (either as globals or as zero-argument functions returning `i32`)
* Read their values to obtain the byte offset and length inside linear memory
* Resolve that byte range against the module's `data` segments and extract the raw bytes
* Decode the bytes as UTF-8 JSON
* If the `__udon_meta_ptr` / `__udon_meta_len` pair is absent, fall back to resolving a static symbol named `__udon_meta` when the producer toolchain preserves it
* If neither form is present, lowering proceeds with default behavior
* Treat decode failure (invalid UTF-8 or malformed JSON) as an error or warning per `options.strict`

### 2. Check `version`

* Reject unsupported versions
* If strict compatibility is desired, accept only `version == 1`

### 3. Resolve `fields`

* Resolve Wasm-side globals/symbols based on `source`
* Generate the corresponding Udon data-section variables
* If `export = true`, attach `.export <udonName>`
* If `sync.enabled = true`, attach `.sync <udonName>, <mode>`

### 4. Resolve `functions`

* Resolve Wasm functions based on `source`
* Generate the corresponding Udon code-section labels
* If `export = true`, attach `.export <label>`

### 5. Apply `behaviour.syncMode`

* Reflect it in the synchronization setting of the generated UdonBehaviour
* Since there is no direct corresponding line in Udon Assembly, it may be treated as out-of-assembly generation metadata

### 6. Apply `options.memory`

* Resolve `initialPages` and `maxPages` per the order in `spec_linear_memory.md` (meta override, then WASM declaration, then default `256` with `strict = false`)
* Size the outer `SystemObjectArray` to `maxPages`
* Rename the memory variables if `udonName` is provided

---

## Constraints

* `fields[*].sync.mode` must allow only `none | linear | smooth`, matching the actual value domain of Udon Assembly `.sync`
* `functions` event/export metadata applies to code labels and must not be confused with field sync metadata
* `source.kind = "name"` is discouraged because it is fragile with respect to stripping and optimization
* Locating the metadata via a raw `__udon_meta` symbol is likewise fragile; the `__udon_meta_ptr` / `__udon_meta_len` export pair is the recommended form
* JSON is chosen for human readability, but could be replaced with CBOR or another format in the future if needed

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


# Variable Naming

## Problem

Udon Assembly has one flat namespace of variables: every WASM local, global,
constant and every piece of translator state becomes a field of the
UdonBehaviour (`docs/udon_specs.md` §4). Names must be unique, must be
valid Udon identifiers (§4.4), and must not collide with the variables Udon
itself reserves for event parameters or with names the producer chooses in
`__udon_meta`.

## Rules

1. Every name the translator invents starts with `__`. Names chosen by the
   producer (`__udon_meta.fields[*].udonName`, `options.memory.udonName`)
   are used verbatim and should not start with `__`.
2. Function-scoped names embed the function's name: its export name, else
   its `name`-section name, else `f{index}`; with every character outside
   `[A-Za-z0-9_]` replaced by `_`, truncated to 40 characters, and suffixed
   with `_f{index}` if that would collide.
3. A name is a translation error if it is not a valid Udon identifier or is
   already taken.

## Names

| Variable | Name | Defined in |
|---|---|---|
| parameter *i* of a function | `__{fn}_P{i}__` | `spec_call_return_conversion.md` §2 |
| declared local *i* | `__{fn}_L{i}__` | |
| temporary *n* | `__{fn}_T{n}__` | |
| return address slot | `__{fn}_RA__` | §4 |
| return-address constant *n* | `__ra_{n}`, `__ra_halt` | §4, §7 |
| result register *k* | `__ret{k}_{type}` | §4 |
| indirect-call argument *k*, return address | `__ia{k}_{type}`, `__ind_RA` | §4 |
| function table and its image | `__table`, `__table_b64`, `__table_bytes` | §4 |
| recursion stack | `__call_stack`, `__call_stack_top` | §6 |
| initialization state | `__inited`, `__init_RA` | §7 |
| exported global | `__G__{export name}` | |
| other global *i* | `__G__g{i}` | |
| imported global | `__G__imp_{name}` | |
| linear memory, its size | `__G__memory`, `__G__memory_size_pages` | `spec_linear_memory.md` §2 |
| data segment *n*, decode scratch | `__data_{n}`, `__data_bytes` | §8 |
| store arrays | `__st_{type}` | §4 |
| derived-value cache slot *k* (0–7) | `__derived{k}` | §5 |
| `i32` constant | `__c_i32_{value}` (`n` prefix for negatives) | `spec_numeric_conversion.md` §5 |
| byte constant | `__c_u8_{value}` | `spec_linear_memory.md` §3 |
| other constant | `__c_{type}_{hex bits}` | |
| constant pool | `__kpool`, `__kpool_b64` | |
| UTF-8 encoding object | `__utf8` | `spec_host_import_conversion.md` §3 |
| runtime-routine state | `__rt_{n}`, `__trap_msg` | |

`{type}` is `i32`, `i64`, `f32` or `f64`.

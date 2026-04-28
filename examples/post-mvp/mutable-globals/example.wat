;; Post-MVP "mutable-globals" proposal example for wasdon-zig.
;;
;; Demonstrates that:
;;   1. An imported mutable global (`env.host_counter`) is accepted and
;;      lowered to a backing Udon data field. The host (Udon side) writes
;;      that field via the established Udon SetVariable mechanism; the
;;      WASM module observes the writes through normal `global.get`.
;;   2. A module-defined mutable global (`$local`) is emitted as a
;;      mutable Udon data field as well, since Udon has no const concept
;;      for fields — the `mut` flag does not change emission.
;;   3. `global.get` / `global.set` against either kind lower without a
;;      `__unsupported__` annotation.
;;
;; See:
;;   docs/spec_variable_conversion.md  (Mutability subsection)
;;   docs/producer_guide.md            (§1 — mutable globals are accepted)
;;   docs/spec_udonmeta_conversion.md  (__udon_meta schema + locator pair)

(module
  (import "env" "host_counter" (global $host (mut i32)))
  (global $local (mut i32) (i32.const 0))

  (memory (export "memory") 1)

  (func $tick (result i32)
    global.get $host
    i32.const 1
    i32.add
    global.set $local
    global.get $local)
  (export "tick" (func $tick))

  ;; __udon_meta JSON blob describing one local field and one fn binding.
  ;; The pair (__udon_meta_ptr, __udon_meta_len) below points at the byte
  ;; range of this literal in linear memory. Both locators are exported
  ;; as immutable globals whose init expression is a single `i32.const`,
  ;; which is what `evalExportedI32` accepts.
  (data (i32.const 0)
    "{\22version\22:1,\22fields\22:{\22local\22:{\22source\22:{\22kind\22:\22global\22,\22name\22:\22local\22},\22udonName\22:\22__G__local\22}},\22functions\22:{\22tick\22:{\22source\22:{\22kind\22:\22export\22,\22name\22:\22tick\22},\22label\22:\22_update\22,\22event\22:\22Update\22}}}")
  (global $__udon_meta_ptr (export "__udon_meta_ptr") i32 (i32.const 0))
  (global $__udon_meta_len (export "__udon_meta_len") i32 (i32.const 199))
)

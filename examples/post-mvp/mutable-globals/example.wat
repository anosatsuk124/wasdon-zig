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
;;   docs/spec_udonmeta_conversion.md  (sidecar `__udon_meta` JSON contract)
;;
;; The matching `__udon_meta` blob lives in `example.udon_meta.json`
;; alongside this `.wat` (and the generated `.wasm`).

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
)

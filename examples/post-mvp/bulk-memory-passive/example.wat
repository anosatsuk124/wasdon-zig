(module
  (memory (export "memory") 1)
  ;; Passive data segment (mode 0x01). Bytes "Hello\00".
  ;; No `memory.init` / `data.drop` references in this module — the
  ;; segment exists only for the parser-level test of mode 0x01.
  (data "Hello\00")
  (func (export "_start"))
)

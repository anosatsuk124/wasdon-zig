(module
  (memory (export "memory") 1)
  ;; Passive data segment (mode 0x01). 4 bytes "ABCD".
  (data $seg "ABCD")
  (func $do_init
    ;; memory.init copies (n=4) bytes from segment 0 starting at src=0
    ;; into linear memory at dst=100.
    i32.const 100   ;; dst
    i32.const 0     ;; src offset within segment
    i32.const 4     ;; n
    memory.init $seg

    ;; Optional read-back to keep the active address live (result dropped).
    i32.const 100
    i32.load
    drop)
  (export "do_init" (func $do_init))
)

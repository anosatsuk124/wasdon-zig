(module
  (memory (export "memory") 1)
  ;; Passive data segment (mode 0x01). 3 bytes "XYZ".
  (data $seg "XYZ")
  (func $do_drop
    ;; Copy "XYZ" into memory at offset 0, then drop the segment.
    i32.const 0    ;; dst
    i32.const 0    ;; src
    i32.const 3    ;; n
    memory.init $seg
    data.drop $seg)
  (export "do_drop" (func $do_drop))
)

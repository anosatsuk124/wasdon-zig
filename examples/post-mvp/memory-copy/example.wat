(module
  (memory (export "memory") 1)
  (func $copy (param $dst i32) (param $src i32) (param $n i32)
    local.get $dst
    local.get $src
    local.get $n
    memory.copy)
  (export "copy" (func $copy))
  (data (i32.const 0) "{\"version\":1}")
  (global $__udon_meta_ptr (export "__udon_meta_ptr") i32 (i32.const 0))
  (global $__udon_meta_len (export "__udon_meta_len") i32 (i32.const 13))
)

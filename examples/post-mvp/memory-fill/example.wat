(module
  (memory (export "memory") 1)
  (func $fill_64 (param $dst i32)
    local.get $dst
    i32.const 0xCC
    i32.const 64
    memory.fill)
  (export "fill_64" (func $fill_64))
  (data (i32.const 0) "{\"version\":1}")
  (global $__udon_meta_ptr (export "__udon_meta_ptr") i32 (i32.const 0))
  (global $__udon_meta_len (export "__udon_meta_len") i32 (i32.const 13))
)

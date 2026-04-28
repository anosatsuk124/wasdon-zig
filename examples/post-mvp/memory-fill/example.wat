(module
  (memory (export "memory") 1)
  (func $fill_64 (param $dst i32)
    local.get $dst
    i32.const 0xCC
    i32.const 64
    memory.fill)
  (export "fill_64" (func $fill_64))
)

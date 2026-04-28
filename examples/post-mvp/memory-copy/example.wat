(module
  (memory (export "memory") 1)
  (func $copy (param $dst i32) (param $src i32) (param $n i32)
    local.get $dst
    local.get $src
    local.get $n
    memory.copy)
  (export "copy" (func $copy))
)

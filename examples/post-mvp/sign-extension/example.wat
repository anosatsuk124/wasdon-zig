(module
  (memory (export "memory") 1)
  (func $sx_i8 (param $x i32) (result i32)
    local.get $x
    i32.extend8_s)
  (export "sx_i8" (func $sx_i8))
  (func $sx_i16_64 (param $x i64) (result i64)
    local.get $x
    i64.extend16_s)
  (export "sx_i16_64" (func $sx_i16_64))
)

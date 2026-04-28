(module
  (memory (export "memory") 1)
  (func $sat_i32_f32 (param $x f32) (result i32)
    local.get $x
    i32.trunc_sat_f32_s)
  (export "sat_i32_f32" (func $sat_i32_f32))
  (func $sat_u64_f64 (param $x f64) (result i64)
    local.get $x
    i64.trunc_sat_f64_u)
  (export "sat_u64_f64" (func $sat_u64_f64))
  (data (i32.const 0) "{\"version\":1}")
  (global $__udon_meta_ptr (export "__udon_meta_ptr") i32 (i32.const 0))
  (global $__udon_meta_len (export "__udon_meta_len") i32 (i32.const 13))
)

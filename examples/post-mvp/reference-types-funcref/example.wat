(module
  ;; Trivial signature used for the call_indirect.
  (type $sig (func (param i32) (result i32)))

  ;; A concrete callee matching $sig.
  (func $square (type $sig) (param $x i32) (result i32)
    local.get $x
    local.get $x
    i32.mul)

  ;; A funcref table of size 1, pre-populated via an element segment
  ;; pointing at $square.
  (table $tab 1 1 funcref)
  (elem (table $tab) (i32.const 0) func $square)

  ;; Caller: pop x, then `call_indirect (type $sig) (table 0)` with the
  ;; element index already on the stack. With reference-types enabled
  ;; wat2wasm encodes the table index as a uleb128 immediately after the
  ;; type index. table_idx=0 still encodes as the single byte 0x00, but
  ;; the parser must accept any uleb at that position (the byte is no
  ;; longer the MVP "reserved 0x00").
  (func $call_sq (param $x i32) (result i32)
    local.get $x
    i32.const 0           ;; element index in $tab
    call_indirect $tab (type $sig))

  (export "call_sq" (func $call_sq))
  (export "tab" (table $tab))
)

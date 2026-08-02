;; Integers, and the four corners of them: shifts that wrap their count,
;; division that traps two different ways, and a remainder that does not.
(module
  (func (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add)

  (func (export "shl") (param i32 i32) (result i32)
    (i32.shl (local.get 0) (local.get 1)))

  (func (export "div_s") (param i32 i32) (result i32)
    (i32.div_s (local.get 0) (local.get 1)))

  (func (export "rem_s") (param i32 i32) (result i32)
    (i32.rem_s (local.get 0) (local.get 1)))

  (func (export "clz") (param i64) (result i64)
    (i64.clz (local.get 0)))
)

;;= invoke add 1 2 => 3
;;= invoke add 2147483647 1 => -2147483648
;;= invoke shl 1 33 => 2
;;= invoke div_s 7 2 => 3
;;= invoke div_s -7 2 => -3
;;= trap div_s 1 0 => integer divide by zero
;;= trap div_s -2147483648 -1 => integer overflow
;;= invoke rem_s -2147483648 -1 => 0
;;= invoke clz 1 => 63

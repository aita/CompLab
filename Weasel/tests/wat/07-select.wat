;; `select`, `drop`, and the two kinds of local.
(module
  (func (export "pick") (param i32 i32 i32) (result i32)
    (select (local.get 0) (local.get 1) (local.get 2)))
  (func (export "pick_ref") (param i32) (result funcref)
    (select (result funcref) (ref.func 0) (ref.null func) (local.get 0)))
  (func (export "tee") (param i32) (result i32) (local i32)
    (local.set 1 (local.tee 0 (i32.add (local.get 0) (i32.const 1))))
    (i32.add (local.get 0) (local.get 1)))
  (func (export "drop3") (result i32)
    (i32.const 1) (i32.const 2) (i32.const 3)
    drop drop)
  (func (export "null") (param i32) (result i32)
    (ref.is_null (call 1 (local.get 0))))
)

;;= invoke pick 10 20 1 => 10
;;= invoke pick 10 20 0 => 20
;;= invoke tee 1 => 4
;;= invoke drop3 => 1
;;= invoke null 1 => 0
;;= invoke null 0 => 1

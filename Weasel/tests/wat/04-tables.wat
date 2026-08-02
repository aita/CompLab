;; Tables, function references, and the type check `call_indirect` does at run
;; time — the only type check the machine performs at all.
(module
  (type $unary (func (param i32) (result i32)))
  (type $binary (func (param i32 i32) (result i32)))

  (table $t 4 funcref)
  (elem (i32.const 0) $inc $dec)
  (elem $spare funcref (item (ref.func $twice)))
  ;; $add2 is referenced only from inside a body, so it has to be announced.
  (elem declare func $add2)

  (func $inc (param i32) (result i32) (i32.add (local.get 0) (i32.const 1)))
  (func $dec (param i32) (result i32) (i32.sub (local.get 0) (i32.const 1)))
  (func $twice (param i32) (result i32) (i32.mul (local.get 0) (i32.const 2)))
  (func $add2 (param i32 i32) (result i32) (i32.add (local.get 0) (local.get 1)))

  (func (export "apply") (param i32 i32) (result i32)
    (call_indirect $t (type $unary) (local.get 1) (local.get 0)))

  (func (export "install") (result i32)
    (table.init $t $spare (i32.const 2) (i32.const 0) (i32.const 1))
    (call_indirect $t (type $unary) (i32.const 21) (i32.const 2)))

  (func (export "size") (result i32) (table.size $t))
  (func (export "is_null") (param i32) (result i32)
    (ref.is_null (table.get $t (local.get 0))))

  (func (export "wrong_type") (result i32)
    (table.set $t (i32.const 3) (ref.func $add2))
    (call_indirect $t (type $unary) (i32.const 1) (i32.const 3)))
)

;;= invoke apply 0 41 => 42
;;= invoke apply 1 41 => 40
;;= invoke size => 4
;;= invoke is_null 0 => 0
;;= invoke is_null 3 => 1
;;= trap apply 3 0 => uninitialized element
;;= trap apply 4 0 => out of bounds table access
;;= invoke install => 42
;;= trap wrong_type => indirect call type mismatch

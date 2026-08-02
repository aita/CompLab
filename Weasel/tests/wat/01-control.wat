;; Structured control flow. Every branch here becomes a position and two numbers
;; in the plan; `weasel plan tests/wat/01-control.wat` shows what is left.
(module
  ;; `br_if` out of a `block` is how a compiler writes an early return.
  (func (export "clamp") (param i32) (result i32)
    (block $done (result i32)
      (i32.const 0)
      (br_if $done (i32.lt_s (local.get 0) (i32.const 0)))
      (drop)
      (i32.const 100)
      (br_if $done (i32.gt_s (local.get 0) (i32.const 100)))
      (drop)
      (local.get 0)))

  ;; A `loop` label branches backwards, so its target is known the moment the
  ;; label is opened and needs no patching.
  (func (export "sum") (param i32) (result i32) (local $i i32) (local $acc i32)
    (block $break
      (loop $again
        (br_if $break (i32.gt_s (local.get $i) (local.get 0)))
        (local.set $acc (i32.add (local.get $acc) (local.get $i)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $again)))
    (local.get $acc))

  (func (export "pick") (param i32) (result i32)
    (block $d
      (block $c
        (block $b
          (block $a
            (br_table $a $b $c $d (local.get 0)))
          (return (i32.const 10)))
        (return (i32.const 20)))
      (return (i32.const 30)))
    (i32.const 40))

  ;; A block with parameters as well as results: the branch carries one value
  ;; back in, which is what `keep` counts in the plan.
  (func (export "double_until") (param i32) (result i32)
    (local.get 0)
    (loop $l (param i32) (result i32)
      (i32.mul (i32.const 2))
      (local.tee 0)
      (br_if $l (i32.lt_s (local.get 0) (i32.const 100)))))

  (func $fac (export "fac") (param i64) (result i64)
    (if (result i64) (i64.eqz (local.get 0))
      (then (i64.const 1))
      (else (i64.mul (local.get 0)
                     (call $fac (i64.sub (local.get 0) (i64.const 1)))))))

  (func (export "unreachable_is_polymorphic") (result i32)
    unreachable
    i32.add)
)

;;= invoke clamp -5 => 0
;;= invoke clamp 50 => 50
;;= invoke clamp 500 => 100
;;= invoke sum 10 => 55
;;= invoke sum 0 => 0
;;= invoke pick 0 => 10
;;= invoke pick 1 => 20
;;= invoke pick 2 => 30
;;= invoke pick 3 => 40
;;= invoke pick 99 => 40
;;= invoke double_until 1 => 128
;;= invoke fac 20 => 2432902008176640000
;;= trap unreachable_is_polymorphic => unreachable

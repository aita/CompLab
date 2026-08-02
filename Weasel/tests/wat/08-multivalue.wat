;; Multi-value: blocks that take parameters, functions that return several
;; values, and branches that carry more than one across. `keep` in the plan is
;; larger than 1 only here.
(module
  (type $pair (func (param i32 i32) (result i32 i32)))

  (func $swap (export "swap") (type $pair)
    (local.get 1) (local.get 0))

  (func (export "sub_of_swap") (param i32 i32) (result i32)
    (call $swap (local.get 0) (local.get 1))
    (i32.sub))

  ;; The block takes two values and gives two back, and the branch out of it
  ;; carries both.
  (func (export "pick2") (param i32) (result i32)
    (i32.const 10)
    (i32.const 20)
    (block $out (param i32 i32) (result i32 i32)
      (br_if $out (local.get 0))
      (drop) (drop)
      (i32.const 30) (i32.const 40))
    (i32.add))

  ;; `if` with parameters: both arms start from the same two values.
  (func (export "gap") (param i32 i32) (result i32)
    (local.get 0) (local.get 1)
    (if (param i32 i32) (result i32) (i32.lt_s (local.get 0) (local.get 1))
      (then (i32.sub))
      (else (drop) (drop) (i32.const 0))))

  ;; Recursion deep enough to run the frame stack out.
  (func $deep (export "deep") (param i32) (result i32)
    (if (result i32) (local.get 0)
      (then (call $deep (i32.sub (local.get 0) (i32.const 1))))
      (else (i32.const 0))))
)

;;= invoke sub_of_swap 3 10 => 7
;;= invoke pick2 1 => 30
;;= invoke pick2 0 => 70
;;= invoke gap 3 10 => -7
;;= invoke gap 10 3 => 0
;;= invoke deep 100 => 0
;;= trap deep 100000 => call stack exhausted

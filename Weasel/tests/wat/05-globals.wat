;; Globals, and the small constant language their initialisers are written in.
(module
  (global $counter (mut i32) (i32.const 0))
  (global $base i32 (i32.const 100))
  (global (export "answer") i32 (i32.const 42))

  (func (export "bump") (result i32)
    (global.set $counter (i32.add (global.get $counter) (i32.const 1)))
    (global.get $counter))
  (func (export "base") (result i32) (global.get $base))
)

;;= invoke bump => 1
;;= invoke bump => 2
;;= invoke base => 100

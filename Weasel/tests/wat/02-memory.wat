;; Linear memory: little-endian whatever the host is, bounds checked on every
;; access, and grown a page at a time.
(module
  (memory (export "mem") 1 2)
  (data (i32.const 0) "\01\02\03\04")
  (data $late "hello")

  (func (export "load") (param i32) (result i32) (i32.load (local.get 0)))
  (func (export "load8u") (param i32) (result i32) (i32.load8_u (local.get 0)))
  (func (export "load8s") (param i32) (result i32) (i32.load8_s (local.get 0)))
  (func (export "store") (param i32 i32) (i32.store (local.get 0) (local.get 1)))
  (func (export "size") (result i32) (memory.size))
  (func (export "grow") (param i32) (result i32) (memory.grow (local.get 0)))

  (func (export "offset_load") (param i32) (result i32)
    (i32.load offset=4 align=1 (local.get 0)))

  (func (export "init") (result i32)
    (memory.init $late (i32.const 100) (i32.const 0) (i32.const 5))
    (i32.load8_u (i32.const 100)))

  (func (export "fill") (result i32)
    (memory.fill (i32.const 200) (i32.const 0xab) (i32.const 4))
    (i32.load (i32.const 200)))

  (func (export "copy") (result i32)
    (memory.copy (i32.const 300) (i32.const 0) (i32.const 4))
    (i32.load (i32.const 300)))
)

;;= invoke load 0 => 67305985
;;= invoke load8u 0 => 1
;;= invoke load8s 3 => 4
;;= invoke offset_load 0 => 0
;;= invoke size => 1
;;= trap load 65533 => out of bounds memory access
;;= invoke grow 1 => 1
;;= invoke size => 2
;;= invoke grow 1 => -1
;;= invoke init => 104
;;= invoke fill => -1414812757
;;= invoke copy => 67305985

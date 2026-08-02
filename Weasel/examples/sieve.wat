;; The sieve of Eratosthenes, in one page of linear memory, printed through WASI.
;;
;;   weasel run examples/sieve.wat
;;   weasel plan examples/sieve.wat        # what validation left of the loops
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)

  ;; 0..7   an iovec, filled in by $emit
  ;; 8..15  a small decimal buffer, filled backwards
  ;; 1024.. one byte per candidate, 1 for composite
  (global $limit i32 (i32.const 200))
  (global $sieve i32 (i32.const 1024))

  ;; Write one decimal number and a separator. The digits come out backwards, so
  ;; the buffer is filled from its end and the iovec points at where it stopped.
  (func $emit (param $n i32) (local $p i32)
    (local.set $p (i32.const 16))
    (i32.store8 (local.tee $p (i32.sub (local.get $p) (i32.const 1)))
                (i32.const 10))            ;; newline
    (block $done
      (loop $digit
        (i32.store8 (local.tee $p (i32.sub (local.get $p) (i32.const 1)))
                    (i32.add (i32.const 48)
                             (i32.rem_u (local.get $n) (i32.const 10))))
        (local.set $n (i32.div_u (local.get $n) (i32.const 10)))
        (br_if $digit (local.get $n))))
    (i32.store (i32.const 0) (local.get $p))
    (i32.store (i32.const 4) (i32.sub (i32.const 16) (local.get $p)))
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 20))))

  (func (export "_start") (local $i i32) (local $j i32)
    (local.set $i (i32.const 2))
    (block $outer
      (loop $next
        (br_if $outer (i32.gt_u (local.get $i) (global.get $limit)))
        (if (i32.eqz (i32.load8_u (i32.add (global.get $sieve) (local.get $i))))
          (then
            (call $emit (local.get $i))
            ;; Strike out the multiples, starting from i*i.
            (local.set $j (i32.mul (local.get $i) (local.get $i)))
            (block $stop
              (loop $mark
                (br_if $stop (i32.gt_u (local.get $j) (global.get $limit)))
                (i32.store8 (i32.add (global.get $sieve) (local.get $j)) (i32.const 1))
                (local.set $j (i32.add (local.get $j) (local.get $i)))
                (br $mark)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $next))))
)

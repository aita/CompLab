;; The MartenML runtime, for the WebAssembly back end.
;;
;; The counterpart of martenml_runtime.c: the same heap and the same
;; primitives, for a target that has no linker.  There is nothing to link
;; against, so the compiler copies this text into every module it emits and the
;; two halves become one module -- which is why this file is a fragment rather
;; than a `(module ...)`.
;;
;; Every MartenML value is one 64-bit word: an integer, or an address in linear
;; memory.  Addresses are 32 bits wide on this target and the words that hold
;; them are 64, so every load and store wraps.
;;
;; The host is WASI: the three imports below are all the outside world this
;; module has.  Output is buffered here rather than in the host, so that a
;; program that dies half-way through prints what it had already written --
;; `fatal` flushes before it says anything on standard error, exactly as the C
;; runtime's `fflush(stdout)` does.
;;
;; The first page of memory is this file's; the compiler's static data starts
;; at 4096 and the heap starts after that.
;;
;;     0     iovec for fd_write / fd_read: pointer, then length
;;     8     how many bytes the host actually transferred
;;    16     the digits of print_int, filled in backwards          [16, 48)
;;    64     the standard-output buffer                            [64, 1088)
;;   1152    the standard-input buffer                             [1152, 2176)
;;   2560    the messages below                                    [2560, 4096)
;;   4096    where the compiler takes over

(import "wasi_snapshot_preview1" "fd_write"
  (func $fd_write (param i32 i32 i32 i32) (result i32)))
(import "wasi_snapshot_preview1" "fd_read"
  (func $fd_read (param i32 i32 i32 i32) (result i32)))
(import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))

;; Both set by the compiler's `_start`, which is the only place that knows
;; where the static data ends.
(global $heap_next (mut i32) (i32.const 0))
(global $heap_end (mut i32) (i32.const 0))

(global $out_len (mut i32) (i32.const 0))
(global $in_len (mut i32) (i32.const 0))
(global $in_pos (mut i32) (i32.const 0))

(data (i32.const 2560) "martenml: ")
(data (i32.const 2576) "out of memory\n")
(data (i32.const 2592) "Array.make with a negative length\n")
(data (i32.const 2640) "match failure\n")
(data (i32.const 2656) "division by zero\n")
(data (i32.const 2688) "read_int: no integer on standard input\n")

;; ------------------------------------------------------------------ output

;; One fd_write moves as much as it likes, so this is a loop.  A host that
;; reports an error, or that accepts nothing at all, ends it: there is nowhere
;; left to complain to.
(func $write_all (param $fd i32) (param $ptr i32) (param $len i32)
  (block $done
    (loop $again
      (br_if $done (i32.eqz (local.get $len)))
      (i32.store (i32.const 0) (local.get $ptr))
      (i32.store (i32.const 4) (local.get $len))
      (br_if $done
        (call $fd_write (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 8)))
      (br_if $done (i32.eqz (i32.load (i32.const 8))))
      (local.set $ptr (i32.add (local.get $ptr) (i32.load (i32.const 8))))
      (local.set $len (i32.sub (local.get $len) (i32.load (i32.const 8))))
      (br $again))))

(func $flush
  (if (global.get $out_len)
    (then
      (call $write_all (i32.const 1) (i32.const 64) (global.get $out_len))
      (global.set $out_len (i32.const 0)))))

(func $putc (param $c i32)
  (if (i32.ge_u (global.get $out_len) (i32.const 1024)) (then (call $flush)))
  (i32.store8 (i32.add (i32.const 64) (global.get $out_len)) (local.get $c))
  (global.set $out_len (i32.add (global.get $out_len) (i32.const 1))))

;; Everything already written comes out first, so the message lands after the
;; output it belongs to rather than before it.
(func $fatal (param $ptr i32) (param $len i32)
  (call $flush)
  (call $write_all (i32.const 2) (i32.const 2560) (i32.const 10))
  (call $write_all (i32.const 2) (local.get $ptr) (local.get $len))
  (call $proc_exit (i32.const 2))
  (unreachable))

;; ------------------------------------------------------------------- input

;; The next byte of standard input, or -1 once there is none.
(func $getc (result i32)
  (if (i32.ge_u (global.get $in_pos) (global.get $in_len))
    (then
      (i32.store (i32.const 0) (i32.const 1152))
      (i32.store (i32.const 4) (i32.const 1024))
      (if (call $fd_read (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 8))
        (then (return (i32.const -1))))
      (global.set $in_len (i32.load (i32.const 8)))
      (global.set $in_pos (i32.const 0))
      (if (i32.eqz (global.get $in_len)) (then (return (i32.const -1))))))
  (global.set $in_pos (i32.add (global.get $in_pos) (i32.const 1)))
  (i32.load8_u (i32.add (i32.const 1152) (i32.sub (global.get $in_pos) (i32.const 1)))))

(func $is_space (param $c i32) (result i32)
  (i32.or
    (i32.or (i32.eq (local.get $c) (i32.const 32)) (i32.eq (local.get $c) (i32.const 9)))
    (i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 13)))))

;; -------------------------------------------------------------------- heap

;; A bump allocator, as in the C runtime, except that this one can ask the host
;; for more memory instead of reserving it all up front.  Nothing is ever
;; freed: a collector would need the compiler to describe where the pointers
;; are, which is a different project.
(func $martenml_alloc (param $bytes i64) (result i64)
  (local $size i32)
  (local $block i32)
  (if (i64.gt_u (local.get $bytes) (i64.const 1073741824))
    (then (call $fatal (i32.const 2576) (i32.const 14))))
  (local.set $size
    (i32.and (i32.add (i32.wrap_i64 (local.get $bytes)) (i32.const 7)) (i32.const -8)))
  (if (i32.gt_u (i32.add (global.get $heap_next) (local.get $size)) (global.get $heap_end))
    (then
      (if (i32.eq
            (memory.grow
              (i32.div_u (i32.add (local.get $size) (i32.const 65535)) (i32.const 65536)))
            (i32.const -1))
        (then (call $fatal (i32.const 2576) (i32.const 14))))
      (global.set $heap_end (i32.mul (memory.size) (i32.const 65536)))))
  (local.set $block (global.get $heap_next))
  (global.set $heap_next (i32.add (global.get $heap_next) (local.get $size)))
  (i64.extend_i32_u (local.get $block)))

(func $martenml_make_array (param $length i64) (param $init i64) (result i64)
  (local $base i32)
  (local $p i32)
  (local $end i32)
  (if (i64.lt_s (local.get $length) (i64.const 0))
    (then (call $fatal (i32.const 2592) (i32.const 34))))
  (local.set $base
    (i32.wrap_i64 (call $martenml_alloc (i64.mul (local.get $length) (i64.const 8)))))
  (local.set $p (local.get $base))
  (local.set $end
    (i32.add (local.get $base)
      (i32.mul (i32.wrap_i64 (local.get $length)) (i32.const 8))))
  (block $done
    (loop $again
      (br_if $done (i32.ge_u (local.get $p) (local.get $end)))
      (i64.store (local.get $p) (local.get $init))
      (local.set $p (i32.add (local.get $p) (i32.const 8)))
      (br $again)))
  (i64.extend_i32_u (local.get $base)))

;; ----------------------------------------------------------------- strings

;; A string is a block: one word of length, then that many bytes.
(func $string_length (param $s i64) (result i32)
  (i32.wrap_i64 (i64.load (i32.wrap_i64 (local.get $s)))))

(func $string_bytes (param $s i64) (result i32)
  (i32.add (i32.wrap_i64 (local.get $s)) (i32.const 8)))

(func $martenml_string_concat (param $a i64) (param $b i64) (result i64)
  (local $na i32)
  (local $nb i32)
  (local $block i32)
  (local.set $na (call $string_length (local.get $a)))
  (local.set $nb (call $string_length (local.get $b)))
  (local.set $block
    (i32.wrap_i64
      (call $martenml_alloc
        (i64.extend_i32_u
          (i32.add (i32.const 8) (i32.add (local.get $na) (local.get $nb)))))))
  (i64.store (local.get $block)
    (i64.extend_i32_u (i32.add (local.get $na) (local.get $nb))))
  (memory.copy (i32.add (local.get $block) (i32.const 8))
    (call $string_bytes (local.get $a)) (local.get $na))
  (memory.copy (i32.add (i32.add (local.get $block) (i32.const 8)) (local.get $na))
    (call $string_bytes (local.get $b)) (local.get $nb))
  (i64.extend_i32_u (local.get $block)))

(func $martenml_string_equal (param $a i64) (param $b i64) (result i64)
  (local $n i32)
  (local $p i32)
  (local $q i32)
  (local.set $n (call $string_length (local.get $a)))
  (if (i32.ne (local.get $n) (call $string_length (local.get $b)))
    (then (return (i64.const 0))))
  (local.set $p (call $string_bytes (local.get $a)))
  (local.set $q (call $string_bytes (local.get $b)))
  (block $done
    (loop $again
      (br_if $done (i32.eqz (local.get $n)))
      (if (i32.ne (i32.load8_u (local.get $p)) (i32.load8_u (local.get $q)))
        (then (return (i64.const 0))))
      (local.set $p (i32.add (local.get $p) (i32.const 1)))
      (local.set $q (i32.add (local.get $q) (i32.const 1)))
      (local.set $n (i32.sub (local.get $n) (i32.const 1)))
      (br $again)))
  (i64.const 1))

;; -------------------------------------------------------------- primitives

;; These return a word because the compiler gives every call a result; the ones
;; whose MartenML type is `unit` answer 0.

(func $martenml_print_string (param $s i64) (result i64)
  (local $p i32)
  (local $n i32)
  (local.set $p (call $string_bytes (local.get $s)))
  (local.set $n (call $string_length (local.get $s)))
  (if (i32.gt_u (local.get $n) (i32.const 1024))
    (then
      ;; Too big to be worth copying into the buffer twice.
      (call $flush)
      (call $write_all (i32.const 1) (local.get $p) (local.get $n)))
    (else
      (block $done
        (loop $again
          (br_if $done (i32.eqz (local.get $n)))
          (call $putc (i32.load8_u (local.get $p)))
          (local.set $p (i32.add (local.get $p) (i32.const 1)))
          (local.set $n (i32.sub (local.get $n) (i32.const 1)))
          (br $again)))))
  (i64.const 0))

;; The digits come out backwards, so they are written down from the end of the
;; buffer and read back forwards.  Negation is done on the magnitude as an
;; unsigned number, which is what keeps the most negative integer -- whose
;; negation does not fit -- printing correctly.
(func $martenml_print_int (param $n i64) (result i64)
  (local $p i32)
  (local $negative i32)
  (local.set $p (i32.const 48))
  (local.set $negative (i64.lt_s (local.get $n) (i64.const 0)))
  (if (local.get $negative)
    (then (local.set $n (i64.sub (i64.const 0) (local.get $n)))))
  (loop $digits
    (local.set $p (i32.sub (local.get $p) (i32.const 1)))
    (i32.store8 (local.get $p)
      (i32.add (i32.const 48)
        (i32.wrap_i64 (i64.rem_u (local.get $n) (i64.const 10)))))
    (local.set $n (i64.div_u (local.get $n) (i64.const 10)))
    (br_if $digits (i64.ne (local.get $n) (i64.const 0))))
  (if (local.get $negative)
    (then
      (local.set $p (i32.sub (local.get $p) (i32.const 1)))
      (i32.store8 (local.get $p) (i32.const 45))))
  (block $done
    (loop $again
      (br_if $done (i32.ge_u (local.get $p) (i32.const 48)))
      (call $putc (i32.load8_u (local.get $p)))
      (local.set $p (i32.add (local.get $p) (i32.const 1)))
      (br $again)))
  (i64.const 0))

(func $martenml_print_char (param $c i64) (result i64)
  (call $putc (i32.and (i32.wrap_i64 (local.get $c)) (i32.const 255)))
  (i64.const 0))

(func $martenml_print_newline (param $unit i64) (result i64)
  (call $putc (i32.const 10))
  (i64.const 0))

(func $martenml_read_int (param $unit i64) (result i64)
  (local $c i32)
  (local $negative i32)
  (local $digits i32)
  (local $n i64)
  ;; Anything already printed -- a prompt, say -- goes out before we block.
  (call $flush)
  (block $found
    (loop $skip
      (local.set $c (call $getc))
      (br_if $skip (call $is_space (local.get $c)))))
  (if (i32.eq (local.get $c) (i32.const 45))
    (then
      (local.set $negative (i32.const 1))
      (local.set $c (call $getc)))
    (else
      (if (i32.eq (local.get $c) (i32.const 43)) (then (local.set $c (call $getc))))))
  (block $done
    (loop $more
      (br_if $done
        (i32.or (i32.lt_s (local.get $c) (i32.const 48))
                (i32.gt_s (local.get $c) (i32.const 57))))
      (local.set $digits (i32.const 1))
      (local.set $n
        (i64.add (i64.mul (local.get $n) (i64.const 10))
          (i64.extend_i32_s (i32.sub (local.get $c) (i32.const 48)))))
      (local.set $c (call $getc))
      (br $more)))
  (if (i32.eqz (local.get $digits))
    (then (call $fatal (i32.const 2688) (i32.const 39))))
  (if (local.get $negative) (then (local.set $n (i64.sub (i64.const 0) (local.get $n)))))
  (local.get $n))

;; --------------------------------------------------------------- the traps

;; Neither returns; the result type is there because the compiler binds the
;; result of every call it emits.
(func $martenml_match_failure (result i64)
  (call $fatal (i32.const 2640) (i32.const 14))
  (unreachable))

(func $martenml_division_by_zero
  (call $fatal (i32.const 2656) (i32.const 17))
  (unreachable))

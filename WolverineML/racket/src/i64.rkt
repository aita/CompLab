#lang racket/base

;; Sixty-four bit arithmetic.
;;
;; Racket's integers are exact and unbounded, which is the right default and the
;; wrong width: the language this compiles has a 64-bit `int` that wraps.  So
;; every operation that can leave the range comes back through `wrap`, and the
;; shifts say what they do past 63 rather than leaving it to the host.

(provide wrap
         i64+ i64- i64* i64-quotient i64-remainder
         i64-and i64-or i64-xor i64-shl i64-shr
         i64-min i64-max
         unsigned)

(define WIDTH 64)
(define SPAN (expt 2 WIDTH))
(define i64-min (- (expt 2 (sub1 WIDTH))))
(define i64-max (sub1 (expt 2 (sub1 WIDTH))))

;; The value `n` has when it is kept in 64 bits.
(define (wrap n)
  (define m (modulo n SPAN))
  (if (> m i64-max) (- m SPAN) m))

;; The same bits read as unsigned, which is what `u<` and `u>=` compare.
(define (unsigned n) (modulo n SPAN))

(define (i64+ a b) (wrap (+ a b)))
(define (i64- a b) (wrap (- a b)))
(define (i64* a b) (wrap (* a b)))

;; `sdiv` truncates towards zero, and `min_int / -1` wraps to `min_int`.
(define (i64-quotient a b) (wrap (quotient a b)))
(define (i64-remainder a b) (wrap (remainder a b)))

(define (i64-and a b) (wrap (bitwise-and (unsigned a) (unsigned b))))
(define (i64-or a b) (wrap (bitwise-ior (unsigned a) (unsigned b))))
(define (i64-xor a b) (wrap (bitwise-xor (unsigned a) (unsigned b))))

;; A shift of 64 or more is not the host's business to decide.
(define (i64-shl a b)
  (cond [(negative? b) #f]
        [(>= b WIDTH) 0]
        [else (wrap (arithmetic-shift a b))]))

(define (i64-shr a b)
  (cond [(negative? b) #f]
        [(>= b WIDTH) (if (negative? a) -1 0)]
        [else (arithmetic-shift a (- b))]))

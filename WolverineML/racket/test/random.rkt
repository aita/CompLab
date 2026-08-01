#lang racket/base

;; Random programs, compiled and checked against what the oracle says they mean.

(require rackunit
         racket/list
         racket/string
         "oracle.rkt"
         (prefix-in driver: "../src/driver.rkt")
         (prefix-in emit: "../src/emit.rkt"))

(provide random-tests)

(define CONFIGURATIONS
  (list (cons "default" (driver:options #t #t #f))
        (cons "no-opt" (driver:options #t #f #f))
        (cons "spilling" (driver:options #t #t 10))))

;; The first line that differs is the useful part of the answer.
(define (agrees source expected opts what)
  (define done (driver:run source opts))
  (check-equal? (driver:outcome-code done) 0 (driver:outcome-stderr done))
  (define got (string-split (driver:outcome-stdout done) "\n"))
  (define want (string-split expected "\n"))
  (for ([g (in-list got)] [w (in-list want)] [i (in-naturals)])
    (check-equal? g w (format "~a, line ~a" what i)))
  (check-equal? (length got) (length want) what))

(define random-tests
  (test-suite
   "random"

   (test-case "arithmetic"
     (when (driver:toolchain-ready?)
       (for* ([seed (in-list '(1 2))] [c (in-list CONFIGURATIONS)])
         (define-values (source expected) (arithmetic seed 25))
         (agrees source expected (cdr c) (format "arithmetic ~a [~a]" seed (car c))))))

   (test-case "arrays, loops and branches"
     (when (driver:toolchain-ready?)
       (for* ([seed (in-list '(1 2))] [c (in-list CONFIGURATIONS)])
         (define-values (source expected) (imperative seed 8))
         (agrees source expected (cdr c) (format "imperative ~a [~a]" seed (car c))))))

   (test-case "a cycle of copies can be done without a scratch register"
     ;; Force the swap: the borrowed register is what usually hides this path.
     (when (driver:toolchain-ready?)
       ;; The recursive call swaps its two arguments, so the copies into `x0`
       ;; and `x1` are a cycle that has to be untangled somehow.
       (define source (string-append
                       "fun swap (a : int, b : int) : int =\n"
                       "  if a > b then swap (b, a) else b * 10 + a\n"
                       "val () = (printInt (swap (1, 2)); print (\" \"); "
                       "printInt (swap (7, 3)))\n"))
       (check-equal? (driver:outcome-stdout (driver:run source (driver:default-options)))
                     "21 73")
       (parameterize ([emit:borrow-nothing? #t])
         (check-true (regexp-match? #rx"eor x"
                                    (driver:compile-to-asm source (driver:default-options)))
                     "no swap was written")
         (check-equal? (driver:outcome-stdout (driver:run source (driver:default-options)))
                       "21 73"))))))

(module+ test (require rackunit/text-ui) (void (run-tests random-tests)))

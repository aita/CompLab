;;; Random programs, compiled and checked against what the oracle says they mean.

(use-modules ((srfi srfi-1) #:select (first second))
             (srfi srfi-64)
             (ice-9 format)
             (harness)
             (oracle)
             ((wolv driver) #:select (options default-options run outcome-code
                                      outcome-stdout outcome-stderr toolchain-ready?
                                      compile-to-asm))
             ((wolv emit) #:select (borrow-nothing?)))

(define CONFIGURATIONS
  (list (cons "default" (options #t #t #f))
        (cons "no-opt" (options #t #f #f))
        (cons "spilling" (options #t #t 10))))

;; The first line that differs is the useful part of the answer.
(define (agrees source expected opts what)
  (let* ((done (run source opts))
         (got (string-split (outcome-stdout done) #\newline))
         (want (string-split expected #\newline)))
    (test-equal (format #f "~a exits cleanly" what) 0 (outcome-code done))
    (let loop ((got got) (want want) (i 0))
      (unless (or (null? got) (null? want))
        (test-equal (format #f "~a, line ~a" what i) (car want) (car got))
        (loop (cdr got) (cdr want) (+ i 1))))
    (test-equal (format #f "~a, how many lines" what) (length want) (length got))))

(with-suite
 "random"
 (lambda ()
   (skip-unless
    (toolchain-ready?)

    (test-assert "arithmetic"
      (begin
        (for-each
         (lambda (seed)
           (call-with-values (lambda () (arithmetic seed 25))
             (lambda (source expected)
               (for-each (lambda (c)
                           (agrees source expected (cdr c)
                                   (format #f "arithmetic ~a [~a]" seed (car c))))
                         CONFIGURATIONS))))
         '(1 2))
        #t))

    (test-assert "arrays, loops and branches"
      (begin
        (for-each
         (lambda (seed)
           (call-with-values (lambda () (imperative seed 8))
             (lambda (source expected)
               (for-each (lambda (c)
                           (agrees source expected (cdr c)
                                   (format #f "imperative ~a [~a]" seed (car c))))
                         CONFIGURATIONS))))
         '(1 2))
        #t))

    ;; The recursive call swaps its two arguments, so the copies into `x0` and
    ;; `x1` are a cycle that has to be untangled somehow.  The borrowed register
    ;; is what usually hides the other path.
    (test-assert "a cycle of copies can be done without a scratch register"
      (let ((source (lines "fun swap (a : int, b : int) : int ="
                           "  if a > b then swap (b, a) else b * 10 + a"
                           "val () = (printInt (swap (1, 2)); print (\" \"); printInt (swap (7, 3)))")))
        (test-equal "with one to borrow" "21 73"
          (outcome-stdout (run source (default-options))))
        (parameterize ((borrow-nothing? #t))
          (test-assert "a swap was written"
            (string-contains (compile-to-asm source (default-options)) "eor x"))
          (test-equal "and it does the same thing" "21 73"
            (outcome-stdout (run source (default-options)))))
        #t)))))

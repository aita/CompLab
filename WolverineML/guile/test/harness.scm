;;; What every test file starts with.
;;;
;;; SRFI-64 is the test framework, which Guile ships.  What it does not have is
;;; a runner that says nothing when everything passes, so this defines one — a
;;; line per failure and a line at the end — and a suite that leaves an exit
;;; status behind it, so `run-tests.sh` can tell whether it passed.
;;;
;;; `raises?` is the other thing: whether a thunk threw the compiler's own
;;; error, of the kind meant, with the message expected.

(define-module (harness)
  #:use-module (srfi srfi-64)
  #:use-module (ice-9 format)
  #:use-module (ice-9 textual-ports)
  #:use-module (wolv diag)
  #:export (with-suite raises? read-file lines skip-unless))

(define (quiet-runner name)
  (let ((runner (test-runner-null))
        (ran 0)
        (failed 0))
    (test-runner-on-test-end! runner
      (lambda (r)
        (set! ran (+ ran 1))
        (case (test-result-kind r)
          ((fail xpass)
           (set! failed (+ failed 1))
           (format #t "FAIL ~a/~a\n" name (or (test-runner-test-name r) "?"))
           (let ((expected (test-result-ref r 'expected-value 'unknown))
                 (actual (test-result-ref r 'actual-value 'unknown)))
             (unless (eq? expected 'unknown)
               (format #t "      wanted ~s\n      got    ~s\n" expected actual))))
          (else #t))))
    (test-runner-on-final! runner
      (lambda (r)
        (format #t "~a: ~a/~a tests~a\n" name (- ran failed) ran
                (if (zero? failed) "" (format #f ", ~a failures" failed)))))
    runner))

(define (with-suite name thunk)
  (test-runner-factory (lambda () (quiet-runner name)))
  (test-begin name)
  (thunk)
  (let ((failed (+ (test-runner-fail-count (test-runner-current))
                   (test-runner-xpass-count (test-runner-current)))))
    (test-end name)
    (exit (if (zero? failed) 0 1))))

;; A test that only means anything with a toolchain to hand.
(define-syntax-rule (skip-unless ready? body ...)
  (if ready?
      (begin body ...)
      (format #t "  (skipped: no ARM toolchain)\n")))

;; Whether `thunk` raised a `kind` error whose message contains `substring`.
(define (raises? kind substring thunk)
  (catch 'wolv
    (lambda () (thunk) #f)
    (lambda (key got-kind at message)
      (and (eq? got-kind kind) (string-contains message substring) #t))))

(define (read-file path) (call-with-input-file path get-string-all))

(define (lines . parts) (string-append (string-join parts "\n") "\n"))

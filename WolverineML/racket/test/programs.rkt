#lang racket/base

;; End to end: compile to ARMv8, assemble, link, and run it.
;;
;; These are the only tests that need a toolchain.  Without a cross `gcc` and
;; `qemu-aarch64` they skip rather than fail, so the rest of the suite still runs
;; on a machine that has neither.

(require rackunit
         racket/list
         racket/file
         racket/string
         racket/runtime-path
         (prefix-in driver: "../src/driver.rkt"))

(provide programs-tests)

(define-runtime-path HERE ".")
(define-runtime-path EXAMPLES "../examples")

(define (programs)
  (sort (for/list ([p (in-list (directory-list (build-path HERE "programs")))]
                   #:when (regexp-match? #rx"[.]wol$" (path->string p)))
          (path->string p))
        string<?))

(define (examples)
  (sort (for/list ([p (in-list (directory-list EXAMPLES))]
                   #:when (regexp-match? #rx"[.]wol$" (path->string p)))
          (path->string p))
        string<?))

(define CONFIGURATIONS
  (list (cons "default" (driver:options #t #t #f))
        (cons "no-opt" (driver:options #t #f #f))
        (cons "no-checks" (driver:options #f #t #f))
        (cons "spilling" (driver:options #t #t 12))
        (cons "spilling-no-opt" (driver:options #t #f 12))))

(define (ran source opts [stdin ""])
  (define done (driver:run source opts stdin))
  (check-equal? (driver:outcome-code done) 0 (driver:outcome-stderr done))
  (driver:outcome-stdout done))

(define programs-tests
  (test-suite
   "programs"

   (test-case "every option gives the same answer; only the code differs"
     (cond
       [(not (driver:toolchain-ready?)) (printf "  (skipped: no ARM toolchain)\n")]
       [else
        (for ([name (in-list (programs))])
          (define source (file->string (build-path HERE "programs" name)))
          (define want (file->string (build-path HERE "programs"
                                                 (regexp-replace #rx"[.]wol$" name ".out"))))
          (for ([c (in-list CONFIGURATIONS)])
            (check-equal? (ran source (cdr c)) want (format "~a [~a]" name (car c)))))]))

   (test-case "the examples agree with themselves"
     ;; No expected output on file: what matters is that the stages agree.
     (cond
       [(not (driver:toolchain-ready?)) (void)]
       [else
        (for ([name (in-list (examples))])
          (define source (file->string (build-path EXAMPLES name)))
          (define baseline (ran source (driver:default-options)))
          (check-true (positive? (string-length baseline)))
          (for ([c (in-list (rest CONFIGURATIONS))] #:unless (string=? (car c) "no-checks"))
            (check-equal? (ran source (cdr c)) baseline (format "~a [~a]" name (car c)))))]))

   (test-case "the checks catch what they are for"
     (cond
       [(not (driver:toolchain-ready?)) (void)]
       [else
        (for ([case (in-list
                     (list (cons "val a = array (3, 0)\nval () = printInt (a[5])"
                                 "outside an array")
                           (cons (string-append "type t = { x : int }\nval n : t = nil\n"
                                                "val () = printInt (n.x)")
                                 "field of nil")
                           (cons "var z = 0\nval () = printInt (7 / z)"
                                 "division by zero")))])
          (define done (driver:run (car case) (driver:default-options)))
          (check-equal? (driver:outcome-code done) 1)
          (check-true (and (regexp-match? (regexp-quote (cdr case))
                                          (driver:outcome-stderr done))
                           #t)
                      (cdr case)))]))

   (test-case "a check can be turned off"
     (when (driver:toolchain-ready?)
       (check-equal? (ran "val a = array (3, 0)\nval () = printInt (a[1])\n"
                          (driver:options #f #t #f))
                     "0")))

   (test-case "standard input"
     (when (driver:toolchain-ready?)
       (define source (string-append
                       "var line = \"\"\n"
                       "var c = getChar ()\n"
                       "val () = while c <> \"\" andalso c <> \"\\n\" do "
                       "(line := line ^ c; c := getChar ())\n"
                       "val () = print (\"read: \" ^ line ^ \" (\" ^ "
                       "intToString (size (line)) ^ \")\\n\")\n"))
       (check-equal? (ran source (driver:default-options) "hello\n") "read: hello (5)\n")))

   (test-case "the exit code is the program's"
     (when (driver:toolchain-ready?)
       (define done (driver:run "val () = (print (\"bye\\n\"); exit (3))"
                                (driver:default-options)))
       (check-equal? (driver:outcome-code done) 3)
       (check-equal? (driver:outcome-stdout done) "bye\n")))))

(module+ test (require rackunit/text-ui) (void (run-tests programs-tests)))

;;; End to end: compile to ARMv8, assemble, link, and run it.
;;;
;;; These are the only tests that need a toolchain.  Without a cross `gcc` and
;;; `qemu-aarch64` they skip rather than fail, so the rest of the suite still
;;; runs on a machine that has neither.

(use-modules ((srfi srfi-1) #:select (first second))
             (srfi srfi-64)
             (ice-9 format)
             (ice-9 ftw)
             (harness)
             ((wolv driver) #:select (options default-options run outcome-code
                                      outcome-stdout outcome-stderr toolchain-ready?)))

(define (wol-files directory)
  (sort (filter (lambda (name) (string-suffix? ".wol" name)) (scandir directory))
        string<?))

(define CONFIGURATIONS
  (list (cons "default" (options #t #t #f))
        (cons "no-opt" (options #t #f #f))
        (cons "no-checks" (options #f #t #f))
        (cons "spilling" (options #t #t 12))
        (cons "spilling-no-opt" (options #t #f 12))))

(define* (ran source opts #:optional (stdin ""))
  (let ((done (run source opts stdin)))
    (test-equal "the program exits cleanly" 0 (outcome-code done))
    (outcome-stdout done)))

(with-suite
 "programs"
 (lambda ()
   (skip-unless
    (toolchain-ready?)

    (test-assert "every option gives the same answer; only the code differs"
      (begin
        (for-each
         (lambda (name)
           (let ((source (read-file (string-append "test/programs/" name)))
                 (want (read-file (string-append "test/programs/"
                                                 (string-drop-right name 4) ".out"))))
             (for-each (lambda (c)
                         (test-equal (format #f "~a [~a]" name (car c))
                           want (ran source (cdr c))))
                       CONFIGURATIONS)))
         (wol-files "test/programs"))
        #t))

    ;; No expected output on file: what matters is that the stages agree.
    (test-assert "the examples agree with themselves"
      (begin
        (for-each
         (lambda (name)
           (let* ((source (read-file (string-append "examples/" name)))
                  (baseline (ran source (default-options))))
             (test-assert "an example prints something"
               (positive? (string-length baseline)))
             (for-each (lambda (c)
                         (unless (string=? (car c) "no-checks")
                           (test-equal (format #f "~a [~a]" name (car c))
                             baseline (ran source (cdr c)))))
                       (cdr CONFIGURATIONS))))
         (wol-files "examples"))
        #t))

    (test-assert "the checks catch what they are for"
      (begin
        (for-each
         (lambda (case)
           (let ((done (run (car case) (default-options))))
             (test-equal (format #f "~a: the exit code" (cdr case)) 1 (outcome-code done))
             (test-assert (cdr case)
               (string-contains (outcome-stderr done) (cdr case)))))
         (list (cons "val a = array (3, 0)\nval () = printInt (a[5])"
                     "outside an array")
               (cons (lines "type t = { x : int }" "val n : t = nil"
                            "val () = printInt (n.x)")
                     "field of nil")
               (cons "var z = 0\nval () = printInt (7 / z)"
                     "division by zero")))
        #t))

    (test-equal "a check can be turned off" "0"
      (ran "val a = array (3, 0)\nval () = printInt (a[1])\n" (options #f #t #f)))

    (test-equal "standard input" "read: hello (5)\n"
      (ran (lines "var line = \"\""
                  "var c = getChar ()"
                  "val () = while c <> \"\" andalso c <> \"\\n\" do (line := line ^ c; c := getChar ())"
                  "val () = print (\"read: \" ^ line ^ \" (\" ^ intToString (size (line)) ^ \")\\n\")")
           (default-options)
           "hello\n"))

    (test-assert "the exit code is the program's"
      (let ((done (run "val () = (print (\"bye\\n\"); exit (3))" (default-options))))
        (and (= 3 (outcome-code done))
             (string=? "bye\n" (outcome-stdout done))))))))

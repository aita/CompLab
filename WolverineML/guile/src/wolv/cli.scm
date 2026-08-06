;;; The command line.
;;;
;;; The arguments are picked apart by hand rather than by `(ice-9 getopt-long)`,
;;; which stops reading flags at the first thing that is not one: `wolv emit -s
;;; ssa prog.wol` puts a flag after two of them, and every other tree in this
;;; repository accepts that.

(define-module (wolv cli)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (first second))
  #:use-module (ice-9 format)
  #:use-module (ice-9 textual-ports)
  #:use-module (wolv diag)
  #:use-module ((wolv driver) #:prefix driver:)
  #:export (wolv-main))

(define COMMANDS '("build" "run" "emit" "check"))

(define USAGE
  (string-join
   '("usage: wolv <command> <file> [options]"
     ""
     "  build   compile and link an executable"
     "  run     build it and run it"
     "  emit    write one stage of the pipeline to standard output"
     "  check   types only"
     ""
     "  -o, --out PATH     where `build` should write the executable"
     "  -s, --stage NAME   which stage `emit` should show:"
     "                     tokens, ast, ir, ssa, opt, dag, mach, flat, ra, asm"
     "      --no-checks    leave out the nil, bounds and divide-by-zero checks"
     "      --no-opt       do not optimise the SSA"
     "      --max-regs N   pretend the machine has N registers, to make it spill")
   "\n"))

;; What the flags said, and what was left over.
(define-class <arguments> ()
  (checks? #:init-value #t #:accessor arguments-checks?)
  (optimise? #:init-value #t #:accessor arguments-optimise?)
  (max-regs #:init-value #f #:accessor arguments-max-regs)
  (stage #:init-value "asm" #:accessor arguments-stage)
  (out #:init-value #f #:accessor arguments-out)
  (rest #:init-value '() #:accessor arguments-rest))

(define (bad template . arguments)
  (format (current-error-port) "wolv: ~a\n" (apply format #f template arguments))
  (exit 1))

(define (complain template . arguments)
  (format (current-error-port) "~a\n" (apply format #f template arguments))
  1)

(define (parse-arguments argv)
  (let ((so-far (make <arguments>)))
    (let read-on ((args argv))
      (define (value-after flags take)
        (and (member (car args) flags)
             (begin
               (when (null? (cdr args)) (bad "`~a` wants a value after it" (car args)))
               (take (second args))
               (read-on (cddr args))
               #t)))
      (cond
       ((null? args)
        (set! (arguments-rest so-far) (reverse (arguments-rest so-far)))
        so-far)
       ((member (car args) '("-h" "--help")) (display USAGE) (newline) (exit 0))
       ((value-after '("-o" "--out") (lambda (v) (set! (arguments-out so-far) v)))
        so-far)
       ((value-after '("-s" "--stage")
                     (lambda (v)
                       (unless (member v driver:STAGES) (bad "no such stage as `~a`" v))
                       (set! (arguments-stage so-far) v)))
        so-far)
       ((value-after '("--max-regs")
                     (lambda (v)
                       (let ((n (string->number v)))
                         (unless (and n (exact? n) (integer? n) (positive? n))
                           (bad "`--max-regs` wants a number"))
                         (set! (arguments-max-regs so-far) n))))
        so-far)
       ((string=? (car args) "--no-checks")
        (set! (arguments-checks? so-far) #f)
        (read-on (cdr args)))
       ((string=? (car args) "--no-opt")
        (set! (arguments-optimise? so-far) #f)
        (read-on (cdr args)))
       ((and (> (string-length (car args)) 1) (char=? (string-ref (car args) 0) #\-))
        (bad "no such option as `~a`" (car args)))
       (else
        (set! (arguments-rest so-far) (cons (car args) (arguments-rest so-far)))
        (read-on (cdr args)))))))

(define (from-stdin)
  (if (isatty? (current-input-port)) "" (get-string-all (current-input-port))))

;; A `.wol` file becomes an executable of the same name without the suffix.
(define (drop-suffix file)
  (let ((dot (string-rindex file #\.)))
    (if (and dot (string=? (substring file dot) ".wol"))
        (substring file 0 dot)
        (string-append file ".out"))))

(define (read-source file)
  (unless (file-exists? file) (bad "no such file as `~a`" file))
  (call-with-input-file file get-string-all))

(define (wolv-main argv)
  (let* ((args (parse-arguments argv))
         (rest (arguments-rest args)))
    (unless (= (length rest) 2) (bad "wants a command and a file"))
    (let ((command (first rest))
          (file (second rest)))
      (unless (member command COMMANDS)
        (bad "no such command as `~a`: ~a" command (string-join COMMANDS ", ")))
      (let ((opts (driver:options (arguments-checks? args)
                                  (arguments-optimise? args)
                                  (arguments-max-regs args)))
            (source (read-source file)))
        (catch 'wolv
          (lambda ()
            (catch 'wolv-toolchain
              (lambda ()
                (catch 'wolv-out-of-registers
                  (lambda () (do-command command file source opts args))
                  (lambda (key message) (complain "wolv: ~a" message))))
              (lambda (key message) (complain "wolv: ~a" message))))
          (lambda (key kind at message)
            (complain "~a:~a: ~a" file (show-span at) message)))))))

(define (do-command command file source opts args)
  (cond
   ((string=? command "check") (driver:to-ir source opts) 0)
   ((string=? command "emit")
    (display (driver:stage source (arguments-stage args) opts))
    0)
   ((string=? command "build")
    (driver:build source (or (arguments-out args) (drop-suffix file)) opts)
    0)
   (else
    (let ((done (driver:run source opts (from-stdin))))
      (display (driver:outcome-stdout done))
      (display (driver:outcome-stderr done) (current-error-port))
      (driver:outcome-code done)))))

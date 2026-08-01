#lang racket/base

;; The command line.
;;
;; The arguments are picked apart by hand rather than by `racket/cmdline`, which
;; stops reading flags at the first thing that is not one: `wolv emit -s ssa
;; prog.wol` puts a flag after two of them, and every other tree in this
;; repository accepts that.

(require racket/list
         racket/port
         racket/file
         racket/string
         "diag.rkt"
         (prefix-in spill: "spill.rkt")
         (prefix-in driver: "driver.rkt"))

(provide main)

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
(struct arguments (checks? optimise? max-regs stage out rest) #:transparent)

(define (parse argv)
  (let read ([args (vector->list argv)]
             [so-far (arguments #t #t #f "asm" #f '())])
    (define (with-value flags take)
      (and (member (car args) flags)
           (begin (when (null? (cdr args)) (bad "`~a` wants a value after it" (car args)))
                  (read (cddr args) (take (second args))))))
    (cond
      [(null? args) (struct-copy arguments so-far [rest (reverse (arguments-rest so-far))])]
      [(member (car args) '("-h" "--help")) (displayln USAGE) (exit 0)]
      [(with-value '("-o" "--out") (λ (v) (struct-copy arguments so-far [out v])))]
      [(with-value '("-s" "--stage")
                   (λ (v)
                     (unless (member v driver:STAGES) (bad "no such stage as `~a`" v))
                     (struct-copy arguments so-far [stage v])))]
      [(with-value '("--max-regs")
                   (λ (v)
                     (define n (string->number v))
                     (unless (exact-positive-integer? n) (bad "`--max-regs` wants a number"))
                     (struct-copy arguments so-far [max-regs n])))]
      [(string=? (car args) "--no-checks")
       (read (cdr args) (struct-copy arguments so-far [checks? #f]))]
      [(string=? (car args) "--no-opt")
       (read (cdr args) (struct-copy arguments so-far [optimise? #f]))]
      [(and (> (string-length (car args)) 1) (char=? (string-ref (car args) 0) #\-))
       (bad "no such option as `~a`" (car args))]
      [else (read (cdr args)
                  (struct-copy arguments so-far
                               [rest (cons (car args) (arguments-rest so-far))]))])))

(define (main argv)
  (define args (parse argv))
  (unless (= (length (arguments-rest args)) 2) (bad "wants a command and a file"))
  (define command (first (arguments-rest args)))
  (define file (second (arguments-rest args)))
  (unless (member command COMMANDS)
    (bad "no such command as `~a`: ~a" command (string-join COMMANDS ", ")))
  (define opts (driver:options (arguments-checks? args)
                               (arguments-optimise? args)
                               (arguments-max-regs args)))
  (define source
    (with-handlers ([exn:fail:filesystem? (λ (e) (bad "~a" (exn-message e)))])
      (file->string file)))

  (with-handlers ([exn:wolv? (λ (e) (complain "~a:~a" file (exn-message e)))]
                  [driver:exn:toolchain? (λ (e) (complain "wolv: ~a" (exn-message e)))]
                  [spill:exn:out-of-registers? (λ (e) (complain "wolv: ~a" (exn-message e)))])
    (cond
      [(string=? command "check") (driver:to-ir source opts) 0]
      [(string=? command "emit") (display (driver:stage source (arguments-stage args) opts)) 0]
      [(string=? command "build")
       (driver:build source (or (arguments-out args) (drop-suffix file)) opts)
       0]
      [else
       (define done (driver:run source opts (from-stdin)))
       (display (driver:outcome-stdout done))
       (display (driver:outcome-stderr done) (current-error-port))
       (driver:outcome-code done)])))

(define (from-stdin)
  (if (terminal-port? (current-input-port)) "" (port->string (current-input-port))))

;; A `.wol` file becomes an executable of the same name without the suffix.
(define (drop-suffix file)
  (define without (path->string (path-replace-extension (string->path file) #"")))
  (if (string=? without file) (string-append file ".out") without))

(define (bad template . arguments)
  (eprintf "wolv: ~a\n" (apply format template arguments))
  (exit 1))

(define (complain template . arguments)
  (eprintf "~a\n" (apply format template arguments))
  1)

(module+ main
  (exit (main (current-command-line-arguments))))

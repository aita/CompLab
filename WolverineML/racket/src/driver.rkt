#lang racket/base

;; The pipeline, and the toolchain around it.
;;
;;     source ─lex─▶ tokens ─parse─▶ tree ─check─▶ typed tree ─lower─▶ CFG
;;            ─ssa─▶ SSA ─opt─▶ SSA ─select─▶ machine IR ─regalloc─▶ coloured
;;            ─emit─▶ ARMv8
;;
;; Assembling and linking is left to a cross `gcc`, and running to `qemu-aarch64`
;; when the machine underneath is not itself an ARM.
;;
;; The pipeline is one function, stopped where the caller wants to look: a dump
;; is the pipeline halted, not a second description of it that has to be kept in
;; step with the first.

(require racket/list
         racket/string
         racket/system
         racket/port
         racket/file
         racket/runtime-path
         (prefix-in alloc: "allocator.rkt")
         (prefix-in dag: "dag.rkt")
         (prefix-in emit: "emit.rkt")
         (prefix-in ir: "ir.rkt")
         (prefix-in lex: "lexer.rkt")
         (prefix-in low: "lower.rkt")
         (prefix-in mach: "mach.rkt")
         (prefix-in opt: "opt.rkt")
         (prefix-in out: "outofssa.rkt")
         (prefix-in reg: "registers.rkt")
         (prefix-in sel: "select.rkt")
         (prefix-in ssa: "ssa.rkt")
         "astshow.rkt"
         "parser.rkt"
         "typecheck.rkt")

(provide STAGES (struct-out options) default-options
         to-ir compile-module compile-to-asm stage
         cross-cc emulator toolchain-ready? build run
         (struct-out exn:toolchain) (struct-out outcome))

(define STAGES '("tokens" "ast" "ir" "ssa" "opt" "dag" "mach" "flat" "ra" "asm"))

(struct options (checks? optimise? max-regs) #:transparent)
(define (default-options) (options #t #t #f))

(define (machine-of opts)
  (if (options-max-regs opts) (reg:limited (options-max-regs opts)) (reg:whole-machine)))

(define (to-ir source opts)
  (define prog (parse source))
  (check prog)
  (low:lower prog (low:options (options-checks? opts))))

;; The module, and what the allocator decided about each of its functions —
;; empty until the pipeline has run that far.
(define (compile-module source opts [upto "asm"])
  (define m (to-ir source opts))
  (let/ec return
    (define (stop-at? name) (when (string=? upto name) (return m (hash))))
    (stop-at? "ir")
    (ssa:construct-module! m)
    (stop-at? "ssa")
    (when (options-optimise? opts) (opt:optimise! m))
    (stop-at? "opt")
    (for ([f (in-list (ir:module*-funcs m))]) (ssa:split-critical-edges! f))
    ;; The DAGs are a view of this, taken without changing it.
    (stop-at? "dag")
    (sel:select-module! m)
    (mach:verify-module m)
    (stop-at? "mach")
    (out:destruct-module! m)
    (stop-at? "flat")
    (values m (alloc:allocate-module m (machine-of opts)))))

(define (compile-to-asm source opts)
  (define-values (m allocs) (compile-module source opts))
  (emit:emit-module m allocs))

;; Run the pipeline as far as `name`, and show what it has by then.
(define (stage source name opts)
  (cond
    [(string=? name "tokens") (lex:dump (lex:lex source))]
    [(string=? name "ast")
     (define prog (parse source))
     (check prog)
     (show-program prog)]
    [else
     (define-values (m allocs) (compile-module source opts name))
     (cond
       [(string=? name "dag") (show-dags m)]
       [(string=? name "asm") (emit:emit-module m allocs)]
       [else (ir:show-module m allocs)])]))

(define (show-dags m)
  (string-append
   (string-join
    (for/list ([f (in-list (ir:module*-funcs m))])
      (string-append
       (format "fun ~a\n" (ir:func-label f))
       (string-join (for/list ([pair (in-list (sel:graphs f))])
                      (format "~a:\n~a" (car pair) (dag:show (cdr pair))))
                    "\n")))
    "\n\n")
   "\n"))

;; -- the toolchain -----------------------------------------------------------

(struct exn:toolchain exn:fail () #:transparent)

(define (toolchain-error template . arguments)
  (raise (exn:toolchain (apply format template arguments) (current-continuation-marks))))

(define-runtime-path RUNTIME "../runtime/runtime.c")

(define (on-arm?) (and (memq (system-type 'arch) '(aarch64 arm64)) #t))

(define (which name)
  (define found (find-executable-path name))
  (and found (path->string found)))

(define (cross-cc)
  (or (getenv "WOLV_CC")
      (for/or ([name (in-list '("aarch64-linux-gnu-gcc" "aarch64-linux-gnu-cc"
                                                        "aarch64-none-linux-gnu-gcc"))])
        (which name))
      (and (on-arm?) (or (which "cc") (which "gcc")))
      (toolchain-error "no ARM compiler found; install aarch64-linux-gnu-gcc or set WOLV_CC")))

(define (emulator)
  (cond
    [(on-arm?) '()]
    [else
     (define found (or (which "qemu-aarch64") (which "qemu-aarch64-static")))
     (unless found
       (toolchain-error "no qemu-aarch64 found, and this machine is not an ARM"))
     (list found)]))

;; Whether an end-to-end test can run at all, so that one can say it is skipping.
(define (toolchain-ready?)
  (with-handlers ([exn:toolchain? (λ (e) #f)])
    (cross-cc)
    (emulator)
    #t))

(define (build source out opts)
  (define asm (compile-to-asm source opts))
  (define tmp (make-temporary-file "wolv~a" 'directory))
  (define path (build-path tmp "program.s"))
  (define errors (open-output-string))
  (dynamic-wind
   void
   (λ ()
     (display-to-file asm path #:exists 'replace)
     (define ok
       (parameterize ([current-error-port errors] [current-output-port errors])
         (system* (cross-cc) "-static" "-O2" "-o" (if (path? out) (path->string out) out)
                  (path->string path) (path->string RUNTIME))))
     (unless ok (toolchain-error "the assembler refused it:\n~a" (get-output-string errors))))
   (λ () (delete-directory/files tmp))))

;; The exit code, what it printed, and what it printed on the way out.
(struct outcome (code stdout stderr) #:transparent)

(define (run source opts [stdin ""])
  (define tmp (make-temporary-file "wolv~a" 'directory))
  (dynamic-wind
   void
   (λ ()
     (define binary (build-path tmp "program"))
     (build source binary opts)
     (define command (append (emulator) (list (path->string binary))))
     (define stdout (open-output-string))
     (define stderr (open-output-string))
     (define code
       (parameterize ([current-output-port stdout] [current-error-port stderr]
                      [current-input-port (open-input-string stdin)])
         (apply system*/exit-code (car command) (cdr command))))
     (outcome code (get-output-string stdout) (get-output-string stderr)))
   (λ () (delete-directory/files tmp))))

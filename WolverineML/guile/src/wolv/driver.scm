;;; The pipeline, and the toolchain around it.
;;;
;;;     source ─lex─▶ tokens ─parse─▶ tree ─check─▶ typed tree ─lower─▶ CFG
;;;            ─ssa─▶ SSA ─opt─▶ SSA ─select─▶ machine IR ─regalloc─▶ coloured
;;;            ─emit─▶ ARMv8
;;;
;;; Assembling and linking is left to a cross `gcc`, and running to
;;; `qemu-aarch64` when the machine underneath is not itself an ARM.
;;;
;;; The pipeline is one list, stopped where the caller wants to look: a dump is
;;; the pipeline halted, not a second description of it that has to be kept in
;;; step with the first.

(define-module (wolv driver)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (first second any))
  #:use-module (ice-9 format)
  #:use-module (ice-9 textual-ports)
  #:use-module (wolv parser)
  #:use-module (wolv typecheck)
  #:use-module (wolv astshow)
  #:use-module (wolv lexer)
  #:use-module (wolv ir)
  #:use-module (wolv dag)
  #:use-module (wolv select)
  #:use-module ((wolv ssa) #:select (construct-module! split-critical-edges!))
  #:use-module (wolv opt)
  #:use-module ((wolv mach) #:select ((verify-module . mach-verify-module)))
  #:use-module (wolv outofssa)
  #:use-module ((wolv allocator) #:select (allocate-module))
  #:use-module (wolv registers)
  #:use-module (wolv emit)
  #:use-module ((wolv lower) #:prefix low:)
  #:export (STAGES <options> options default-options
            options-checks? options-optimise? options-max-regs
            to-ir compile-module compile-to-asm stage
            cross-cc emulator toolchain-ready? build run
            toolchain-error toolchain-error?
            <outcome> outcome-code outcome-stdout outcome-stderr))

(define STAGES '("tokens" "ast" "ir" "ssa" "opt" "dag" "mach" "flat" "ra" "asm"))

(define-class <options> ()
  (checks? #:init-keyword #:checks? #:getter options-checks?)
  (optimise? #:init-keyword #:optimise? #:getter options-optimise?)
  (max-regs #:init-keyword #:max-regs #:getter options-max-regs))

(define (options checks? optimise? max-regs)
  (make <options> #:checks? checks? #:optimise? optimise? #:max-regs max-regs))

(define (default-options) (options #t #t #f))

(define (machine-of opts)
  (if (options-max-regs opts) (limited (options-max-regs opts)) (whole-machine)))

(define (to-ir source opts)
  (let ((prog (parse source)))
    (check prog)
    (low:lower prog (low:options (options-checks? opts)))))

;; Each pass, under the name of the stage it produces.  Running one and then
;; asking whether the caller wanted to stop there is the whole of `stage`.
(define PIPELINE
  (list (cons "ir" (lambda (m opts) *unspecified*))
        (cons "ssa" (lambda (m opts) (construct-module! m)))
        (cons "opt" (lambda (m opts) (when (options-optimise? opts) (optimise! m))))
        ;; The DAGs are a view of this, taken without changing it.
        (cons "dag" (lambda (m opts) (for-each split-critical-edges! (module-funcs m))))
        (cons "mach" (lambda (m opts) (select-module! m) (mach-verify-module m)))
        (cons "flat" (lambda (m opts) (destruct-module! m)))))

;; The module, and what the allocator decided about each of its functions —
;; empty until the pipeline has run that far.
(define* (compile-module source opts #:optional (upto "asm"))
  (let ((m (to-ir source opts)))
    (let loop ((steps PIPELINE))
      (cond
       ((null? steps) (values m (allocate-module m (machine-of opts))))
       (else
        ((cdr (car steps)) m opts)
        (if (string=? upto (car (car steps)))
            (values m (make-hash-table))
            (loop (cdr steps))))))))

(define (compile-to-asm source opts)
  (call-with-values (lambda () (compile-module source opts))
    (lambda (m allocs) (emit-module m allocs))))

;; Run the pipeline as far as `name`, and show what it has by then.
(define (stage source name opts)
  (cond
   ((string=? name "tokens") (dump (lex source)))
   ((string=? name "ast")
    (let ((prog (parse source)))
      (check prog)
      (show-program prog)))
   (else
    (call-with-values (lambda () (compile-module source opts name))
      (lambda (m allocs)
        (cond
         ((string=? name "dag") (show-dags m))
         ((string=? name "asm") (emit-module m allocs))
         (else (show-module m allocs))))))))

(define (show-dags m)
  (string-append
   (string-join
    (map (lambda (f)
           (string-append
            (format #f "fun ~a\n" (func-label f))
            (string-join (map (lambda (pair)
                                (format #f "~a:\n~a" (car pair) (show (cdr pair))))
                              (graphs f))
                         "\n")))
         (module-funcs m))
    "\n\n")
   "\n"))

;; -- the toolchain -----------------------------------------------------------

(define (toolchain-error template . arguments)
  (throw 'wolv-toolchain (apply format #f template arguments)))

(define (toolchain-error? key) (eq? key 'wolv-toolchain))

;; The runtime is found through the load path, which is where this module was
;; found too, so a compiled tree and a source one agree about where it is.
(define (runtime-path)
  (let ((here (search-path %load-path "wolv/driver.scm")))
    (string-append (dirname (dirname (dirname here))) "/runtime/runtime.c")))

(define (on-arm?) (and (member (utsname:machine (uname)) '("aarch64" "arm64")) #t))

(define (which name)
  (let loop ((dirs (string-split (or (getenv "PATH") "") #\:)))
    (cond
     ((null? dirs) #f)
     (else
      (let ((path (string-append (car dirs) "/" name)))
        (if (and (file-exists? path) (access? path X_OK)) path (loop (cdr dirs))))))))

(define (cross-cc)
  (or (getenv "WOLV_CC")
      (any which '("aarch64-linux-gnu-gcc" "aarch64-linux-gnu-cc"
                   "aarch64-none-linux-gnu-gcc"))
      (and (on-arm?) (or (which "cc") (which "gcc")))
      (toolchain-error
       "no ARM compiler found; install aarch64-linux-gnu-gcc or set WOLV_CC")))

(define (emulator)
  (cond
   ((on-arm?) '())
   (else
    (let ((found (or (which "qemu-aarch64") (which "qemu-aarch64-static"))))
      (unless found
        (toolchain-error "no qemu-aarch64 found, and this machine is not an ARM"))
      (list found)))))

;; Whether an end-to-end test can run at all, so that one can say it is
;; skipping.
(define (toolchain-ready?)
  (catch 'wolv-toolchain
    (lambda () (cross-cc) (emulator) #t)
    (lambda (key message) #f)))

;; -- running a command -------------------------------------------------------

(define scratch-counter 0)

(define (scratch-directory)
  (set! scratch-counter (+ scratch-counter 1))
  (let ((path (format #f "/tmp/wolv-~a-~a" (getpid) scratch-counter)))
    (unless (file-exists? path) (mkdir path))
    path))

(define (remove-directory path)
  (when (file-exists? path)
    (for-each (lambda (name)
                (unless (or (string=? name ".") (string=? name ".."))
                  (delete-file (string-append path "/" name))))
              (scandir* path))
    (rmdir path)))

(define (scandir* path)
  (let ((dir (opendir path)))
    (let loop ((acc '()))
      (let ((name (readdir dir)))
        (cond
         ((eof-object? name) (closedir dir) (reverse acc))
         (else (loop (cons name acc))))))))

(define (write-file path text)
  (call-with-output-file path (lambda (port) (display text port))))

(define (read-file path)
  (if (file-exists? path)
      (call-with-input-file path get-string-all)
      ""))

;; A command, its input, and the three things a run answers with.  The
;; redirections are the shell's, which is the one way of saying "these three
;; streams go to these three files" that needs no process plumbing here.
(define (invoke command stdin-text directory)
  (let ((in (string-append directory "/stdin"))
        (out (string-append directory "/stdout"))
        (err (string-append directory "/stderr")))
    (write-file in stdin-text)
    (let ((status (system (format #f "~a < ~a > ~a 2> ~a"
                                  (string-join (map quoted-argument command) " ")
                                  in out err))))
      (values (or (status:exit-val status) 1) (read-file out) (read-file err)))))

(define (quoted-argument text)
  (string-append "'" (fill-quotes text) "'"))

(define (fill-quotes text)
  (string-join (string-split text #\') "'\\''"))

(define (build source out opts)
  (let ((asm (compile-to-asm source opts))
        (tmp (scratch-directory)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let ((path (string-append tmp "/program.s")))
          (write-file path asm)
          (call-with-values
              (lambda ()
                (invoke (list (cross-cc) "-static" "-O2" "-o" out path (runtime-path))
                        "" tmp))
            (lambda (code stdout stderr)
              (unless (zero? code)
                (toolchain-error "the assembler refused it:\n~a" stderr))))))
      (lambda () (remove-directory tmp)))))

;; The exit code, what it printed, and what it printed on the way out.
(define-class <outcome> ()
  (code #:init-keyword #:code #:getter outcome-code)
  (stdout #:init-keyword #:stdout #:getter outcome-stdout)
  (stderr #:init-keyword #:stderr #:getter outcome-stderr))

(define* (run source opts #:optional (stdin ""))
  (let ((tmp (scratch-directory)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (let ((binary (string-append tmp "/program")))
          (build source binary opts)
          (call-with-values
              (lambda () (invoke (append (emulator) (list binary)) stdin tmp))
            (lambda (code stdout stderr)
              (make <outcome> #:code code #:stdout stdout #:stderr stderr)))))
      (lambda () (remove-directory tmp)))))

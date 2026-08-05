;;;; The pipeline, and the toolchain around it.
;;;;
;;;;     source -lex-> tokens -parse-> tree -check-> typed tree -lower-> CFG
;;;;            -ssa-> SSA -opt-> SSA -select-> machine IR -regalloc-> coloured
;;;;            -emit-> ARMv8
;;;;
;;;; The pipeline is one function, stopped where the caller wants to look: a
;;;; dump is the pipeline halted, not a second description of it that has to be
;;;; kept in step with the first.  `block` and `return-from` are what stop it,
;;;; which is a non-local exit and reads as one.
;;;;
;;;; Assembling and linking is left to a cross `gcc`, and running to
;;;; `qemu-aarch64` when the machine underneath is not itself an ARM.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :asdf))

(defpackage #:wolv.driver
  (:use #:cl)
  (:local-nicknames (#:alloc #:wolv.allocator)
                    (#:astshow #:wolv.astshow)
                    (#:dag #:wolv.dag)
                    (#:emit #:wolv.emit)
                    (#:ir #:wolv.ir)
                    (#:lex #:wolv.lexer)
                    (#:low #:wolv.lower)
                    (#:mach #:wolv.mach)
                    (#:opt #:wolv.opt)
                    (#:out #:wolv.outofssa)
                    (#:parser #:wolv.parser)
                    (#:reg #:wolv.registers)
                    (#:sel #:wolv.select)
                    (#:ssa #:wolv.ssa)
                    (#:types #:wolv.typecheck))
  (:export #:*stages* #:options #:make-options #:default-options
           #:options-checks #:options-optimise #:options-max-regs
           #:to-ir #:compile-module #:compile-to-asm #:stage
           #:toolchain-error #:toolchain-error-message
           #:cross-cc #:emulator #:toolchain-ready-p #:build #:run
           #:outcome #:outcome-status #:outcome-out #:outcome-err))

(in-package #:wolv.driver)

(defparameter *stages*
  '("tokens" "ast" "ir" "ssa" "opt" "dag" "mach" "flat" "ra" "asm"))

(defstruct (options (:constructor make-options (&optional (checks t) (optimise t) (max-regs nil)))
                    (:copier nil))
  (checks t) (optimise t) (max-regs nil))

(defun default-options () (make-options))

(defun machine-of (opts)
  (if (options-max-regs opts)
      (reg:limited (options-max-regs opts))
      (reg:whole-machine)))

(defun to-ir (source opts)
  (let ((prog (parser:parse source)))
    (types:check prog)
    (low:lower prog (low:make-options (options-checks opts)))))

(defun compile-module (source opts &optional (upto "asm"))
  "The pipeline, stopped as soon as UPTO has something to show."
  (let ((m (to-ir source opts)))
    (block pipeline
      (flet ((stop-at (name) (when (string= upto name) (return-from pipeline m))))
        (stop-at "ir")
        (ssa:construct-module m)
        (stop-at "ssa")
        (when (options-optimise opts) (opt:optimise m))
        (stop-at "opt")
        (dolist (f (ir:module-funcs m)) (ssa:split-critical-edges f))
        ;; The DAGs are a view of this, taken without changing it.
        (stop-at "dag")
        (sel:select-module m)
        (mach:verify-module m)
        (stop-at "mach")
        (out:destruct-module m)
        (stop-at "flat")
        (alloc:allocate-module m (machine-of opts))
        m))))

(defun compile-to-asm (source opts)
  (emit:emit-module (compile-module source opts)))

(defun stage (source name opts)
  "Run the pipeline as far as NAME, and show what it has by then."
  (cond
    ((string= name "tokens")
     (format nil "~{~A~^~%~}"
             (loop for tok in (lex:lex source)
                   collect (format nil "~A~C~A~C~A"
                                   (wolv.diag:span-text (lex:token-span tok)) #\Tab
                                   (lex:kind-name (lex:token-kind tok)) #\Tab
                                   (lex:token-text tok)))))
    ((string= name "ast")
     (let ((prog (parser:parse source)))
       (types:check prog)
       (astshow:show-program prog)))
    (t
     (let ((m (compile-module source opts name)))
       (cond ((string= name "dag") (show-dags m))
             ((string= name "asm") (emit:emit-module m))
             (t (ir:show-module m)))))))

(defun show-dags (m)
  (format nil "~{~A~^~%~%~}~%"
          (loop for f in (ir:module-funcs m)
                collect (format nil "fun ~A~%~{~A~^~%~}"
                                (ir:func-label f)
                                (loop for (label . graph) in (sel:graphs f)
                                      collect (format nil "~A:~%~A" label (dag:show graph)))))))

;; -- the toolchain ------------------------------------------------------------

(define-condition toolchain-error (error)
  ((message :initarg :message :reader toolchain-error-message))
  (:report (lambda (c stream) (write-string (toolchain-error-message c) stream))))

(defstruct (outcome (:constructor make-outcome (status out err)) (:copier nil))
  status out err)

(defun arm-host-p ()
  (member (machine-type) '("ARM64" "arm64" "aarch64") :test #'string-equal))

(defun cross-cc ()
  (let ((override (uiop:getenv "WOLV_CC")))
    (when (and override (plusp (length override)))
      (return-from cross-cc override)))
  (dolist (name '("aarch64-linux-gnu-gcc" "aarch64-linux-gnu-cc"
                  "aarch64-none-linux-gnu-gcc"))
    (let ((found (which name))) (when found (return-from cross-cc found))))
  (when (arm-host-p)
    (let ((native (or (which "cc") (which "gcc"))))
      (when native (return-from cross-cc native))))
  (error 'toolchain-error
         :message "no ARM compiler found; install aarch64-linux-gnu-gcc or set WOLV_CC"))

(defun emulator ()
  (when (arm-host-p) (return-from emulator '()))
  (dolist (name '("qemu-aarch64" "qemu-aarch64-static"))
    (let ((found (which name))) (when found (return-from emulator (list found)))))
  (error 'toolchain-error
         :message "no qemu-aarch64 found, and this machine is not an ARM"))

(defun which (name)
  (let ((found (with-output-to-string (s)
                 (ignore-errors
                  (uiop:run-program (list "sh" "-c" (format nil "command -v ~A" name))
                                    :output s :ignore-error-status t)))))
    (let ((trimmed (string-trim '(#\Newline #\Space) found)))
      (when (plusp (length trimmed)) trimmed))))

(defun toolchain-ready-p ()
  (and (ignore-errors (cross-cc)) (ignore-errors (progn (emulator) t)) t))

(defun runtime-path ()
  "The runtime is a file of this system, so the system is what is asked for it:
`*load-truename*` is inside ASDF's cache once it is compiling there."
  (asdf:system-relative-pathname "wolv" "runtime/runtime.c"))

(defun build (source out opts)
  (let ((asm (compile-to-asm source opts)))
    (uiop:with-temporary-file (:pathname path :type "s" :keep nil)
      (with-open-file (stream path :direction :output :if-exists :supersede)
        (write-string asm stream))
      (multiple-value-bind (stdout stderr status)
          (uiop:run-program (list (cross-cc) "-static" "-O2" "-o" (namestring out)
                                  (namestring path) (namestring (runtime-path)))
                            :output :string :error-output :string
                            :ignore-error-status t)
        (declare (ignore stdout))
        (unless (zerop status)
          (error 'toolchain-error
                 :message (format nil "the assembler refused it:~%~A" stderr)))))))

(defun run (source opts &optional (stdin ""))
  (uiop:with-temporary-file (:pathname binary :keep nil)
    ;; The linker has to make the file itself, or it inherits the temporary
    ;; file's mode and comes out without the execute bit.
    (uiop:delete-file-if-exists binary)
    (build source binary opts)
    (multiple-value-bind (stdout stderr status)
        (uiop:run-program (append (emulator) (list (namestring binary)))
                          :input (make-string-input-stream stdin)
                          :output :string :error-output :string
                          :ignore-error-status t)
      (make-outcome status (or stdout "") (or stderr "")))))

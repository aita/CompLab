;;;; Compile every source file in order, and stop at the first complaint.
;;;;
;;;; `make.sh` uses this to build the image; on its own it is what says whether
;;;; the tree still compiles clean.

(require :asdf)

(defparameter *files*
  '("diag" "i64" "types" "ast" "lexer" "parser" "typecheck" "astshow"
    "ir" "lower" "ssa" "regset" "liveness" "opt" "mach" "dag" "select"
    "outofssa" "registers" "hints" "spill" "graph" "copies" "allocator"
    "emit" "driver" "cli"))

(defun build (&key (files *files*) (root "src/"))
  (handler-bind ((warning #'muffle-warning))
    (dolist (name files)
      (let ((path (merge-pathnames (format nil "~A~A.lisp" root name))))
        (when (probe-file path)
          (multiple-value-bind (fasl warned failed) (compile-file path :verbose nil :print nil)
            (declare (ignore warned))
            (when failed
              (format *error-output* "~&;; ~A did not compile~%" name)
              (sb-ext:exit :code 1))
            (load fasl)))))))

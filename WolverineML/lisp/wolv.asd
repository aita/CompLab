;;;; WolverineML: a small ML-flavoured language, compiled to ARMv8.

(defsystem "wolv"
  :description "WolverineML, compiled to ARMv8 (AArch64)"
  :author "the WolverineML tree"
  :depends-on ("uiop")
  :components
  ((:module "src"
    :serial t
    :components ((:file "diag")
                 (:file "i64")
                 (:file "types")
                 (:file "ast")
                 (:file "lexer")
                 (:file "parser")
                 (:file "typecheck")
                 (:file "astshow")
                 (:file "ir")
                 (:file "lower")
                 (:file "ssa")
                 (:file "regset")
                 (:file "liveness")
                 (:file "opt")
                 (:file "mach")
                 (:file "dag")
                 (:file "select")
                 (:file "outofssa")
                 (:file "registers")
                 (:file "hints")
                 (:file "spill")
                 (:file "graph")
                 (:file "copies")
                 (:file "allocator")
                 (:file "emit")
                 (:file "driver")
                 (:file "cli"))))
  :in-order-to ((test-op (test-op "wolv/test"))))

(defsystem "wolv/test"
  :description "The tests"
  :depends-on ("wolv")
  :components
  ((:module "test"
    :serial t
    :components ((:file "harness")
                 (:file "lexer")
                 (:file "parser")
                 (:file "typecheck")
                 (:file "middle")
                 (:file "allocator")
                 (:file "oracle")
                 (:file "random")
                 (:file "programs"))))
  :perform (test-op (o c) (uiop:symbol-call :wolv.test :run-all)))

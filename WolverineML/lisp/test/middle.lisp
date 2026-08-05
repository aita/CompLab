;;;; SSA construction, the optimiser, and instruction selection.

(defpackage #:wolv.test.middle
  (:use #:cl #:wolv.test)
  (:local-nicknames (#:dag #:wolv.dag) (#:driver #:wolv.driver) (#:ir #:wolv.ir)
                    (#:live #:wolv.liveness) (#:low #:wolv.lower)
                    (#:mach #:wolv.mach) (#:opt #:wolv.opt) (#:parser #:wolv.parser)
                    (#:sel #:wolv.select) (#:ssa #:wolv.ssa) (#:types #:wolv.typecheck)))

(in-package #:wolv.test.middle)

(in-suite "middle")

(defun lines (&rest parts) (format nil "~{~A~^~%~}~%" parts))

(defun built (source &optional checks)
  (let ((prog (parser:parse source)))
    (types:check prog)
    (low:lower prog (low:make-options checks))))

(defun in-ssa (source &optional checks)
  (let ((m (built source checks)))
    (ssa:construct-module m)
    m))

(defun selected (source &optional checks)
  (let ((m (in-ssa source checks)))
    (opt:optimise m)
    (dolist (f (ir:module-funcs m)) (ssa:split-critical-edges f))
    (sel:select-module m)
    m))

(defun func-named (m name)
  (find name (ir:module-funcs m) :key #'ir:func-name :test #'string=))

(defun instructions (f)
  (loop for b in (ir:walk f) append (ir:block-instrs b)))

(defun forms (source &optional (name "f") checks)
  (loop for i in (instructions (func-named (selected source checks) name))
        when (typep i 'mach:i-mach) collect (mach:form i)))

(defun count-of (xs x) (count x xs :test #'equal))

(defparameter *loop-source*
  (lines "fun count (n : int) : int ="
         "  let var i = 0"
         "      var total = 0"
         "  in"
         "    while i < n do (total := total + i; i := i + 1);"
         "    total"
         "  end"
         "val () = printInt (count (10))"))

(defun function-source (body)
  (lines (format nil "fun f (a : int, b : int, c : int) : int = ~A" body)
         "val () = printInt (f (1, 2, 3))"))

(defun tour-source () (read-file (tree-file "examples/tour.wol")))

;; -- SSA ----------------------------------------------------------------------

(deftest "lowering writes a variable more than once"
  (let* ((f (second (ir:module-funcs (built *loop-source*))))
         (written (make-hash-table :test #'eql)))
    (dolist (i (instructions f))
      (when (ir:defs i) (incf (gethash (ir:defs i) written 0))))
    (is (loop for n being the hash-values of written thereis (> n 1)))
    (is (every (lambda (b) (null (ir:block-phis b))) (ir:walk f)))))

(deftest "construction gives one definition and phis"
  (let ((f (second (ir:module-funcs (in-ssa *loop-source*)))))
    (ssa:verify f)
    (is (some (lambda (b) (ir:block-phis b)) (ir:walk f)) "a loop needs phis")))

(deftest "every function of the tour verifies"
  (dolist (f (ir:module-funcs (in-ssa (tour-source) t)))
    (ssa:verify f)))

(deftest "the dominators of a diamond"
  (let* ((m (in-ssa (lines "fun f (c : bool) : int = if c then 1 else 2"
                           "val () = printInt (f (true))")))
         (f (second (ir:module-funcs m)))
         (dom (ssa:dominance f)))
    (dolist (label (ir:func-order f))
      (is (ssa:dominates-p dom (ir:func-entry f) label)))
    (let ((joins (remove-if-not (lambda (b) (> (length (ir:block-preds b)) 1)) (ir:walk f))))
      (is joins "a diamond has a join")
      (dolist (join joins)
        (is= (ir:func-entry f)
             (gethash (ir:block-label join) (ssa:dominance-idom dom)))))))

(deftest "a phi names exactly its predecessors"
  (dolist (f (ir:module-funcs (in-ssa *loop-source*)))
    (dolist (b (ir:walk f))
      (dolist (phi (ir:block-phis b))
        (is= (sort (copy-list (ir:block-preds b)) #'string<)
             (sort (copy-list (ir:phi-preds phi)) #'string<))))))

;; -- the optimiser ------------------------------------------------------------

(deftest "constants fold"
  (let ((m (in-ssa "val () = printInt (2 * 3 + 4)")))
    (opt:optimise m)
    (is= '(10) (loop for i in (instructions (first (ir:module-funcs m)))
                     when (typep i 'ir:i-const) collect (ir:value i)))))

(deftest "dead code goes"
  (let ((m (in-ssa (lines "fun f (n : int) : int = let val unused = n * n in n + 1 end"
                          "val () = printInt (f (2))"))))
    (opt:optimise m)
    (is (notany (lambda (i) (and (typep i 'ir:i-bin) (string= (ir:op i) "*")))
                (instructions (second (ir:module-funcs m)))))))

(deftest "unreachable blocks go"
  (let ((m (in-ssa "val () = if true then print (\"a\") else print (\"b\")")))
    (opt:optimise m)
    (is= '("wol_print")
         (loop for i in (instructions (first (ir:module-funcs m)))
               when (typep i 'ir:i-call) collect (ir:callee i)))))

(deftest "splitting leaves phis only after a jump"
  (let ((m (in-ssa *loop-source* t)))
    (opt:optimise m)
    (dolist (f (ir:module-funcs m))
      (ssa:split-critical-edges f)
      (ssa:verify f)
      (dolist (b (ir:walk f))
        (when (> (length (ir:succs b)) 1)
          (dolist (succ (ir:succs b))
            (is (null (ir:block-phis (ir:block-of f succ))))))))))

;; -- the tiles ----------------------------------------------------------------

(deftest "multiply-add is one instruction"
  (let ((chosen (forms (function-source "a + b * c"))))
    (is (member "madd" chosen :test #'equal))
    (is (not (member "mul" chosen :test #'equal)))))

(deftest "multiply-subtract is one instruction"
  (let ((chosen (forms (function-source "a - b * c"))))
    (is (member "msub" chosen :test #'equal))
    (is (not (member "mul" chosen :test #'equal)))))

(deftest "a shifted operand beats a multiply-add"
  ;; `a + b * 8` is one instruction with a shift and two as a multiply-add.
  (let ((chosen (forms (function-source "a + b * 8"))))
    (is= 1 (count-of chosen "adds"))
    (is (not (member "madd" chosen :test #'equal)))
    (is (not (member "lsli" chosen :test #'equal)))))

(deftest "a small constant is an immediate"
  (is= '("addi") (forms (function-source "a + 5")))
  (is= '("addi" "subi") (forms (function-source "(a + 5) - 7"))))

(deftest "a large constant is not"
  (is (member "const" (forms (function-source "a + 100000")) :test #'equal)))

(deftest "a multiply by a power of two is a shift"
  (let ((chosen (forms (function-source "a * 8"))))
    (is (member "lsli" chosen :test #'equal))
    (is (not (member "mul" chosen :test #'equal)))))

(deftest "a comparison read only by its branch sets the flags"
  (let* ((source (lines "fun f (a : int) : int = if a < 3 then 1 else 2"
                        "val () = printInt (f (1))"))
         (codes (loop for f in (ir:module-funcs (selected source))
                      append (loop for b in (ir:walk f)
                                   for term = (ir:terminator b)
                                   when (typep term 'ir:i-cbr) collect (ir:code term)))))
    (is (member "lt" codes :test #'equal))
    (is (not (member "cset" (forms source) :test #'equal)))))

(deftest "a comparison read by something else is a value"
  (is (member "cset"
              (forms (lines "fun f (a : int) : bool = a < 3" "val () = print (\"x\")"))
              :test #'equal)))

(deftest "an array element takes two instructions"
  (let ((text (driver:compile-to-asm
               (lines "val a = array (4, 0)" "val () = printInt (a[2] + a[3])")
               (driver:make-options nil t nil))))
    (is= 2 (count-if (lambda (l) (and (> (length l) 5)
                                      (string= "	ldr " (subseq l 0 5))))
                     (split-lines text)))))

;; -- what the plan is for -----------------------------------------------------

(deftest "a constant read twice is still an immediate"
  ;; It costs nothing to repeat, so two readers may both take it.
  (let ((chosen (forms (function-source "(a + 1) * (b + 1)"))))
    (is= 2 (count-of chosen "addi"))
    (is (not (member "const" chosen :test #'equal)))))

(deftest "a chain of additions is not deferred to its last line"
  ;; Folding a whole spine would keep every term live until the end.
  (let* ((m (selected
             (lines "fun sum (a : int, b : int, c : int, d : int, e : int, f : int) : int ="
                    "  a + b + c + d + e + f"
                    "val () = printInt (sum (1, 2, 3, 4, 5, 6))")))
         (f (func-named m "sum")))
    (is (<= (live:pressure f (live:analyse f)) 8))))

(deftest "a node read twice is computed once"
  (is= 1 (count-of (forms (function-source "let val t = a * b in t + t end")) "mul")))

(deftest "the graph counts its readers"
  (let* ((f (func-named (selected (function-source "a + b")) "f"))
         (l (live:analyse f)))
    (dolist (b (ir:walk f))
      (let ((g (dag:build b (live:live-out l (ir:block-label b)))))
        (loop for n across (dag:dag-nodes g)
              do (is= (loop for other across (dag:dag-nodes g)
                            sum (count (dag:node-index n) (dag:node-operands other)))
                      (dag:node-users n)))))))

(deftest "selection keeps it in SSA"
  (dolist (f (ir:module-funcs (selected (function-source "a + b * c + 8") t)))
    (ssa:verify f)))

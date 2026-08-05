;;;; The data-flow DAG of one basic block.
;;;;
;;;; Instruction selection wants to see a block as expressions, not as a list:
;;;; `a + (i << 3)` is one ARM instruction and `a + b*c` is another, and
;;;; neither is visible while the operands are separate lines with names in
;;;; between.  So each block is read into a graph -- a node per instruction, an
;;;; edge per operand -- and the selector covers that graph with instructions.
;;;;
;;;; It is a graph and not a tree because a value can be read twice.  That is
;;;; what `users` counts, and it is what decides whether a node may be folded
;;;; into the instruction that reads it or has to become an instruction of its
;;;; own: a node read twice would otherwise be computed twice.  A value that
;;;; leaves the block counts as read as well, and so does one a phi in a
;;;; successor names.
;;;;
;;;; Only pure nodes are ever folded, and only into a reader whose instruction
;;;; really absorbs them.  Both halves matter.  Folding moves a computation to
;;;; where it is read, which is fine for arithmetic and not fine for a load,
;;;; because a store in between would change what it reads; and folding a chain
;;;; of nodes that nothing absorbs would move a whole expression to its last
;;;; line, leaving every value it read alive until then.  So the selector plans
;;;; first -- it asks, of each node with one reader, whether that reader has a
;;;; tile that takes it -- and everything else is computed where it was
;;;; written.

(defpackage #:wolv.dag
  (:use #:cl)
  (:local-nicknames (#:ir #:wolv.ir)
                    (#:rs #:wolv.regset))
  (:export #:node #:node-index #:node-instr #:node-operands #:node-users
           #:node-reader #:node-escapes #:node-value #:alone-p
           #:dag #:dag-nodes #:node-of #:rematerialisable #:constant-of
           #:build #:show))

(in-package #:wolv.dag)

(defstruct (node (:constructor make-node (index instr operands)) (:copier nil))
  index
  instr
  operands            ; a node in this block, or NIL for a value from outside
  (users 0)
  (reader nil)        ; the only node that reads it, when there is one
  (escapes nil))      ; read after the block ends, or by a phi in a successor

(defun node-value (n) (ir:defs (node-instr n)))

(defun alone-p (n)
  "Read exactly once, inside the block, and computable where read."
  (and (= (node-users n) 1)
       (not (node-escapes n))
       (typep (node-instr n) 'ir:i-bin)))

(defstruct (dag (:constructor make-dag ()) (:copier nil))
  (nodes (make-array 0 :adjustable t :fill-pointer t))
  (by-value (make-hash-table :test #'eql)))

(defun node-of (d index)
  (and index (aref (dag-nodes d) index)))

(defun rematerialisable (d index)
  "A constant, which costs nothing to repeat and is often not an instruction at
all once it has become an immediate operand."
  (let ((n (node-of d index)))
    (and n (not (node-escapes n)) (typep (node-instr n) 'ir:i-const) n)))

(defun constant-of (d index)
  "The value at INDEX, if it is a constant -- however many read it.

Even one that has to exist in a register for somebody else can be an immediate
here, so this asks less than folding does."
  (let ((n (node-of d index)))
    (and n (typep (node-instr n) 'ir:i-const) (ir:value (node-instr n)))))

(defun build (b live-out)
  "Read a block into a graph.  LIVE-OUT includes what the phis will read."
  (let ((d (make-dag)))
    (loop for instr in (ir:block-instrs b)
          for i from 0
          do (let* ((operands (loop for r in (ir:uses instr)
                                    collect (gethash r (dag-by-value d))))
                    (n (make-node i instr operands)))
               (vector-push-extend n (dag-nodes d))
               (let ((defined (ir:defs instr)))
                 (when defined (setf (gethash defined (dag-by-value d)) i)))
               (dolist (operand operands)
                 (when operand
                   (let ((read (aref (dag-nodes d) operand)))
                     (incf (node-users read))
                     (setf (node-reader read)
                           (if (= (node-users read) 1) i nil)))))))
    (loop for n across (dag-nodes d)
          do (let ((value (node-value n)))
               (when (and value (rs:member value live-out))
                 (setf (node-escapes n) t))))
    d))

(defun plain (r) (format nil "%~D" r))

(defun show (d)
  (format nil "~{~A~^~%~}"
          (loop for n across (dag-nodes d)
                collect (let ((reads (format nil "~{~A~^, ~}"
                                             (loop for o in (node-operands n)
                                                   collect (if o (princ-to-string o) "-"))))
                              (marks (concatenate 'string
                                                  (if (node-escapes n) "*" "")
                                                  (if (ir:has-effect-p (node-instr n)) "!" ""))))
                          (format nil "  ~3@A~2A ~38A reads [~A]  users ~D"
                                  (node-index n) marks
                                  (ir:show (node-instr n) #'plain)
                                  reads (node-users n))))))

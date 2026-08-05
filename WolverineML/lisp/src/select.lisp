;;;; Instruction selection: cover the DAG with ARM instructions.
;;;;
;;;; Every node that has to become a register of its own is tiled, largest tile
;;;; first, pulling its foldable operands into the tile as it goes.  The tiles
;;;; are the things ARM can do in one instruction that the IR needs several
;;;; nodes to say:
;;;;
;;;;     a + b * c            madd
;;;;     a - b * c            msub
;;;;     a + (b << k)         add with a shifted operand
;;;;     a + 4095             add with an immediate
;;;;     a * 8                lsl
;;;;     [a + 24]             a load with the addition as its displacement
;;;;     a < b, then branch   cmp, and a branch on the flags
;;;;
;;;; What comes out is still the same CFG, and still in SSA -- a tile defines
;;;; one new register -- so liveness, the allocator and the verifier carry on
;;;; as before.  What has gone is the guesswork the emitter used to do with its
;;;; peepholes: an instruction is now chosen where the whole expression is
;;;; visible, rather than by looking at the line before.

(defpackage #:wolv.select
  (:use #:cl)
  (:local-nicknames (#:dag #:wolv.dag)
                    (#:ir #:wolv.ir)
                    (#:live #:wolv.liveness)
                    (#:mach #:wolv.mach))
  (:export #:select #:select-module #:graphs))

(in-package #:wolv.select)

;; What `add`, `sub` and `cmp` take as an immediate operand.
(defconstant +immediate+ 4095)

(defparameter *logical* '(("and" . "and") ("or" . "orr") ("xor" . "eor")))
(defparameter *shifts* '(("shl" . "lsl") ("shr" . "asr")))

(defclass selector ()
  ((func :initarg :func :reader func)
   (graph :initarg :graph :reader graph)
   (out :initform '() :accessor out)          ; in reverse, until `run` is done
   (done :initform (make-hash-table :test #'eql) :reader done)
   (absorbed :initform (make-hash-table :test #'eql) :reader absorbed)))

(defun select-module (m)
  (dolist (f (ir:module-funcs m)) (select f)))

(defun select (f)
  (let ((l (live:analyse f)))
    (dolist (b (ir:walk f))
      (let ((g (dag:build b (live:live-out l (ir:block-label b)))))
        (setf (ir:block-instrs b)
              (run (make-instance 'selector :func f :graph g)))))))

(defun graphs (f)
  "The DAGs a selection would work on, for `wolv emit -s dag`."
  (let ((l (live:analyse f)))
    (loop for b in (ir:walk f)
          collect (cons (ir:block-label b)
                        (dag:build b (live:live-out l (ir:block-label b)))))))

(defun run (sel)
  (plan sel)
  (let ((nodes (dag:dag-nodes (graph sel))))
    (loop for i from 0 below (length nodes)
          for n = (aref nodes i)
          do (cond
               ((gethash i (absorbed sel)))            ; part of the tile that reads it
               ((dag:rematerialisable (graph sel) i))  ; computed where a register wants it
               ((fuse-comparison sel i))
               (t (setf (gethash i (done sel)) t)
                  (tile (dag:node-instr n) n sel)))))
  (nreverse (out sel)))

(defun plan (sel)
  "Decide which nodes a tile is going to swallow, before emitting any.

Nothing may be deferred on the chance that its reader takes it.  A node left
out of the order and then not absorbed would be computed at its reader instead,
and a chain of those -- `a + b + c + ...`, where every term has one reader --
would move the whole sum to its last line and keep every term alive until then."
  (loop for n across (dag:dag-nodes (graph sel))
        do (when (and (dag:alone-p n) (dag:node-reader n))
             (let ((reader (aref (dag:dag-nodes (graph sel)) (dag:node-reader n))))
               (when (swallows-p (dag:node-instr reader) reader n sel)
                 (setf (gethash (dag:node-index n) (absorbed sel)) t))))))

;; -- whether the instruction chosen for a reader has room for a node ----------

(defgeneric swallows-p (reader-instr reader node sel)
  (:method (reader-instr reader node sel)
    (declare (ignore reader-instr reader node sel))
    nil))

(defmethod swallows-p ((reader-instr ir:i-bin) reader n sel)
  (when (member (ir:op reader-instr) '("+" "-") :test #'string=)
    (and (eql (second (dag:node-operands reader)) (dag:node-index n))
         (or (as-shift sel (dag:node-index n)) (bin-op-p n "*")))))

(defmethod swallows-p ((reader-instr ir:i-load) reader n sel)
  (and (eql (first (dag:node-operands reader)) (dag:node-index n))
       (displaces sel n (ir:offset reader-instr))
       t))

(defmethod swallows-p ((reader-instr ir:i-store) reader n sel)
  (and (eql (first (dag:node-operands reader)) (dag:node-index n))
       (displaces sel n (ir:offset reader-instr))
       t))

(defun displaces (sel n offset)
  "`[pointer + 24]`, when what is added to the pointer is a constant."
  (when (bin-op-p n "+")
    (let ((value (constant-at sel (second (dag:node-operands n)))))
      (when value
        (let ((total (+ offset value)))
          (cond ((and (<= 0 total 32760) (zerop (mod total ir:+word+))) total)
                ((<= -256 total 255) total)
                (t nil)))))))

;; -- emitting -----------------------------------------------------------------

(defun emit (sel instr) (push instr (out sel)))

(defun emit-mach (sel form dst srcs &key (imm 0) (symbol "") (effect nil))
  (emit sel (mach:i-mach form dst srcs imm symbol effect)))

(defun operand (sel index reg)
  "The register holding an operand, computing it here if it was deferred.

Only two kinds of node were left out of the order: a constant, which is tiled
the first time somebody needs it in a register and read from there afterwards,
and a node the plan said would be absorbed, which ends up here only if the tile
that was to absorb it changed its mind."
  (let ((n (dag:node-of (graph sel) index)))
    (when (or (null n) (gethash (dag:node-index n) (done sel)))
      (return-from operand reg))
    (let ((deferred (or (gethash (dag:node-index n) (absorbed sel))
                        (dag:rematerialisable (graph sel) (dag:node-index n)))))
      (unless deferred (return-from operand reg))
      (setf (gethash (dag:node-index n) (done sel)) t)
      (tile (dag:node-instr n) n sel))))

(defun at (sel index reg) (operand sel index reg))

(defun force (sel index)
  "Compute a deferred operand for a reader that has no tile to take it."
  (let ((n (dag:node-of (graph sel) index)))
    (when n (operand sel index (or (dag:node-value n) 0)))))

(defun constant-at (sel index) (dag:constant-of (graph sel) index))

(defun bin-op-p (n op)
  (and (typep (dag:node-instr n) 'ir:i-bin)
       (string= (ir:op (dag:node-instr n)) op)))

;; -- one node -----------------------------------------------------------------

(defgeneric tile (instr node sel)
  (:documentation "Choose an instruction for NODE, and answer with the register
it left its value in."))

(defmethod tile ((instr ir:instr) n sel)
  ;; Moves, calls, slot accesses and the terminator are machine instructions
  ;; already, and a phi is not in this list at all.  None of them folds
  ;; anything, so every operand that was left to be folded has to be computed
  ;; here instead.
  (dolist (index (dag:node-operands n)) (force sel index))
  (emit sel instr)
  (or (ir:defs instr) 0))

(defmethod tile ((instr ir:i-const) n sel)
  (declare (ignore n))
  (emit-mach sel "const" (ir:dst instr) '() :imm (ir:value instr))
  (ir:dst instr))

(defmethod tile ((instr ir:i-str-const) n sel)
  (declare (ignore n))
  (emit-mach sel "adr" (ir:dst instr) '() :symbol (ir:symbol-of instr))
  (ir:dst instr))

(defmethod tile ((instr ir:i-bin) n sel)
  (arithmetic sel n (ir:dst instr) (ir:op instr) (ir:lhs instr) (ir:rhs instr))
  (ir:dst instr))

(defmethod tile ((instr ir:i-cmp) n sel)
  (compare sel n (ir:op instr) (ir:lhs instr) (ir:rhs instr))
  (emit-mach sel "cset" (ir:dst instr) '() :symbol (mach:condition-code (ir:op instr)))
  (ir:dst instr))

(defmethod tile ((instr ir:i-load) n sel)
  (multiple-value-bind (pointer offset)
      (address sel (first (dag:node-operands n)) (ir:base instr) (ir:offset instr))
    (emit-mach sel "ldr" (ir:dst instr) (list pointer) :imm offset))
  (ir:dst instr))

(defmethod tile ((instr ir:i-store) n sel)
  (let ((value (at sel (second (dag:node-operands n)) (ir:src instr))))
    (multiple-value-bind (pointer offset)
        (address sel (first (dag:node-operands n)) (ir:base instr) (ir:offset instr))
      (emit-mach sel "str" nil (list pointer value) :imm offset :effect t)))
  (ir:src instr))

;; -- the tiles ----------------------------------------------------------------

(defun arithmetic (sel n dst op lhs rhs)
  (cond
    ((member op '("+" "-") :test #'string=) (additive sel n dst op lhs rhs))
    ((string= op "*") (multiply sel n dst lhs rhs))
    ((string= op "/") (emit-mach sel "sdiv" dst (both sel n lhs rhs)))
    ((member op '("shl" "shr") :test #'string=) (shift sel n dst op lhs rhs))
    ((member op '("and" "or" "xor") :test #'string=) (logical sel n dst op lhs rhs))
    (t (error "no instruction for `~A`" op))))

(defun both (sel n lhs rhs)
  "Both operands in registers, which is what the plain forms want."
  (list (at sel (first (dag:node-operands n)) lhs)
        (at sel (second (dag:node-operands n)) rhs)))

(defun additive (sel n dst op lhs rhs)
  "`add` and `sub`, in whichever of their four forms fits.

Each of these answers with what it emitted, or `nil` when it does not fit, so
the order they are preferred in is the order they are written in.  A shifted
operand comes first: `a + b * 8` is one instruction that way and two as a
multiply-add, because the 8 would need a register."
  (or (shift-into sel n dst op lhs rhs)
      (multiply-into sel n dst op lhs rhs)
      (immediate-right sel n dst op lhs)
      (immediate-left sel n dst op rhs)
      (plain-additive sel n dst op lhs rhs)))

(defun immediate-right (sel n dst op lhs)
  (let ((value (constant-at sel (second (dag:node-operands n)))))
    (when (and value (<= 0 value +immediate+))
      (emit-mach sel (if (string= op "+") "addi" "subi") dst
                 (list (at sel (first (dag:node-operands n)) lhs))
                 :imm value))))

(defun immediate-left (sel n dst op rhs)
  "Only addition may take its constant from the other side."
  (let ((value (and (string= op "+")
                    (constant-at sel (first (dag:node-operands n))))))
    (when (and value (<= 0 value +immediate+))
      (emit-mach sel "addi" dst (list (at sel (second (dag:node-operands n)) rhs))
                 :imm value))))

(defun plain-additive (sel n dst op lhs rhs)
  (emit-mach sel (if (string= op "+") "add" "sub") dst (both sel n lhs rhs)))

(defun multiply (sel n dst lhs rhs)
  (let ((value (constant-at sel (second (dag:node-operands n)))))
    (if (and value (plusp value) (zerop (logand value (1- value))))
        (emit-mach sel "lsli" dst (list (at sel (first (dag:node-operands n)) lhs))
                   :imm (1- (integer-length value)))
        (emit-mach sel "mul" dst (both sel n lhs rhs)))))

(defun shift (sel n dst op lhs rhs)
  (let ((value (constant-at sel (second (dag:node-operands n)))))
    (if (and value (<= 0 value) (< value 64))
        (emit-mach sel (concatenate 'string (cdr (assoc op *shifts* :test #'string=)) "i")
                   dst (list (at sel (first (dag:node-operands n)) lhs)) :imm value)
        (emit-mach sel (cdr (assoc op *shifts* :test #'string=)) dst (both sel n lhs rhs)))))

(defun logical (sel n dst op lhs rhs)
  (if (and (string= op "xor")
           (eql (constant-at sel (second (dag:node-operands n))) 1))
      ;; Which is how `not` arrives.
      (emit-mach sel "eori" dst (list (at sel (first (dag:node-operands n)) lhs)) :imm 1)
      (emit-mach sel (cdr (assoc op *logical* :test #'string=)) dst (both sel n lhs rhs))))

(defun multiply-into (sel n dst op lhs rhs)
  "`a + b * c` and `a - b * c` are one instruction each."
  (declare (ignore rhs))
  (let ((product (dag:node-of (graph sel) (second (dag:node-operands n)))))
    (when (and product (dag:alone-p product) (bin-op-p product "*"))
      (let* ((pi* (dag:node-instr product))
             (factors (list (at sel (first (dag:node-operands product)) (ir:lhs pi*))
                            (at sel (second (dag:node-operands product)) (ir:rhs pi*)))))
        (emit-mach sel (if (string= op "+") "madd" "msub") dst
                   (append factors (list (at sel (first (dag:node-operands n)) lhs))))
        t))))

(defun shift-into (sel n dst op lhs rhs)
  "The second operand of an `add` may be shifted on the way in."
  (declare (ignore rhs))
  (let ((found (as-shift sel (second (dag:node-operands n)))))
    (when found
      (destructuring-bind (shifted . amount) found
        (let ((si (dag:node-instr shifted)))
          (emit-mach sel (if (string= op "+") "adds" "subs") dst
                     (list (at sel (first (dag:node-operands n)) lhs)
                           (at sel (first (dag:node-operands shifted)) (ir:lhs si)))
                     :imm amount)
          t)))))

(defun as-shift (sel index)
  "A `x << k` that can be folded, however it was written: `* 8` says it too.

This decides nothing and emits nothing, so the plan and the tiles can both ask
it and get the same answer."
  (let ((n (dag:node-of (graph sel) index)))
    (when (and n (dag:alone-p n) (typep (dag:node-instr n) 'ir:i-bin))
      (let ((amount (constant-at sel (second (dag:node-operands n))))
            (op (ir:op (dag:node-instr n))))
        (when amount
          (cond
            ((string= op "*")
             (when (or (<= amount 0) (not (zerop (logand amount (1- amount)))))
               (return-from as-shift nil))
             (setf amount (1- (integer-length amount))))
            ((string/= op "shl") (return-from as-shift nil)))
          (when (and (<= 0 amount) (< amount 64))
            (cons n amount)))))))

(defun address (sel index base offset)
  "A pointer and a displacement, taking in an addition if there is one."
  (let ((n (dag:node-of (graph sel) index)))
    (when (and n (dag:alone-p n))
      (let ((displaced (displaces sel n offset)))
        (when displaced
          (return-from address
            (values (at sel (first (dag:node-operands n)) (ir:lhs (dag:node-instr n)))
                    displaced))))))
  (values (at sel index base) offset))

;; -- comparisons and the branch that reads them -------------------------------

(defun compare (sel n op lhs rhs)
  (let* ((left (first (dag:node-operands n)))
         (right (second (dag:node-operands n)))
         (value (constant-at sel right)))
    (if (and value (<= 0 value +immediate+))
        (emit-mach sel "cmpi" nil (list (at sel left lhs)) :imm value)
        (emit-mach sel "cmp" nil (list (at sel left lhs) (at sel right rhs))))))

(defun fuse-comparison (sel index)
  "A comparison the branch below it is the only reader of sets the flags."
  (let* ((nodes (dag:dag-nodes (graph sel)))
         (n (aref nodes index)))
    (when (and (typep (dag:node-instr n) 'ir:i-cmp)
               (= (1+ index) (1- (length nodes))))
      (let ((term (dag:node-instr (aref nodes (1- (length nodes)))))
            (instr (dag:node-instr n)))
        (when (and (typep term 'ir:i-cbr)
                   (eql (ir:test term) (ir:dst instr))
                   (= (dag:node-users n) 1)
                   (not (dag:node-escapes n)))
          (compare sel n (ir:op instr) (ir:lhs instr) (ir:rhs instr))
          (setf (ir:code term) (mach:condition-code (ir:op instr)))
          t)))))

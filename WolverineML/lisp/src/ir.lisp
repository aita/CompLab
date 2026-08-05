;;;; The three-address IR, and the control flow graph both IRs are written in.
;;;;
;;;; There are two instruction sets in this compiler.  This module has the
;;;; first: three-address code over virtual registers, which is what lowering
;;;; produces, what `ssa` puts into SSA and what `opt` rewrites.  The second is
;;;; in `mach`, and instruction selection replaces the arithmetic of this one
;;;; with it.
;;;;
;;;; What they share is everything else -- the registers, the blocks, the
;;;; graph, the frame -- so the passes that only care about the shape of a
;;;; function (liveness, dominance, the register allocator, the verifiers) work
;;;; on either, and neither has to know what the other's instructions mean.
;;;; That is what the five generic functions below are for: an instruction says
;;;; which register it writes and which it reads, and nothing outside it has to
;;;; ask what it is.
;;;;
;;;; Those five answers are the same shape for every instruction, so they are
;;;; not written out: `define-instr` takes a class and a list of slots, each
;;;; marked with what it holds, and writes `defs`, `(setf defs)`, `uses`,
;;;; `map-uses`, `has-effect-p` and the printer from that.  An instruction here
;;;; declares which of its slots are registers; the protocol follows.
;;;;
;;;; Nothing here is ARM-specific except that a register holds exactly one
;;;; 64-bit word, and the frame layout at the top, which the emitter and the
;;;; nested functions have to agree about.

(defpackage #:wolv.ir
  (:use #:cl)
  (:export #:+word+ #:+argument-registers+ #:slot-offset
           #:instr #:defs #:uses #:map-uses #:has-effect-p #:show
           #:define-instr
           #:i-const #:i-str-const #:i-move #:i-bin #:i-cmp #:i-load #:i-store
           #:i-load-slot #:i-store-slot #:i-frame-addr #:i-call #:i-phi
           #:i-jmp #:i-cbr #:i-ret #:terminator-p
           #:dst #:src #:value #:op #:lhs #:rhs #:base #:offset #:slot
           #:callee #:args #:target #:test #:then #:els #:code #:symbol-of
           #:phi-arg #:set-phi-arg #:phi-preds #:phi-regs #:remove-phi-arg
           #:rename-phi-pred #:keep-phi-args #:map-phi-args #:phi-args-from
           #:basic-block #:make-block #:block-label #:block-phis #:block-instrs
           #:block-preds #:terminator #:succs #:set-terminator
           #:func #:new-func #:func-label #:func-name #:func-params #:func-depth
           #:func-entry #:func-blocks #:func-order #:func-nregs #:func-nslots
           #:func-static-link-slot #:func-colours #:func-spill-slots #:func-saved
           #:new-reg #:new-slot #:add-block #:walk #:block-of
           #:module #:make-module #:module-funcs #:module-strings #:add-string
           #:rename-target #:recompute-preds #:reachable #:drop-unreachable #:rpo
           #:reg-name #:naming #:show-instr #:show-func #:show-module))

(in-package #:wolv.ir)

(defconstant +word+ 8)

;; How many arguments AAPCS64 passes in registers.  The rest go on the stack,
;; and the frame layout below knows where.
(defconstant +argument-registers+ 8)

(defun slot-offset (slot)
  "Where a frame slot sits, relative to the frame pointer.

Slot 0 of every nested function holds its static link, so a frame chain can be
walked without knowing whose frame it is.  Negative slots are the arguments the
caller had to pass on the stack: they are already in the frame, above the saved
frame record, so nothing has to be copied for them and they never take a
register at entry."
  (if (minusp slot)
      (+ 16 (* +word+ (- (- slot) 1)))
      (- (* +word+ (1+ slot)))))

;; -- what every instruction of either set can be asked ------------------------

(defclass instr ()
  ()
  (:documentation "The base of both instruction sets."))

(defgeneric defs (instr)
  (:documentation "The register it writes, if it writes one.")
  (:method ((i instr)) nil))

(defgeneric (setf defs) (reg instr)
  (:method (reg (i instr))
    (declare (ignore reg))
    (error "~A defines nothing" (class-name (class-of i)))))

(defgeneric uses (instr)
  (:documentation "The registers it reads.  A phi's arguments are read on the
edges, not here, so they are not among them.")
  (:method ((i instr)) '()))

(defgeneric map-uses (instr function)
  (:documentation "Rewrite the registers it reads, in place.")
  (:method ((i instr) function) (declare (ignore function)) nil))

(defgeneric has-effect-p (instr)
  (:documentation "True when it has to be kept even if its result is dead.")
  (:method ((i instr)) nil))

(defgeneric show (instr namer)
  (:method ((i instr) namer) (declare (ignore namer)) "?"))

;; -- the macro that writes those --------------------------------------------

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun slot-spec (spec)
    "NAME, ROLE, DEFAULT and whether there is one.

A slot written out in full has a default even when that default is NIL, which
is why the fourth element is here and `(or default ...)` is not enough."
    (let ((spec (if (consp spec) spec (list spec))))
      (list (first spec) (or (second spec) :plain) (third spec)
            (and (cddr spec) t))))

  (defun slots-with-role (specs role)
    (loop for (name r) in specs when (eq r role) collect name)))

(defmacro define-instr (name slots &body clauses)
  "One instruction: a class, a constructor of the same name, and the five
methods every pass asks it.

Each slot is NAME, or (NAME ROLE), or (NAME ROLE DEFAULT).  ROLE is `:def` for
the register it writes, `:use` for one it reads, `:uses` for a list of them,
and `:plain` -- the default -- for everything that is not a register.  Slots
with a default become optional arguments of the constructor, in order.

The clauses are `(:effect)` or `(:effect EXPR)` for an instruction that must be
kept whatever reads it, `(:reads-when EXPR)` for one that only reads its
registers sometimes, and `(:show EXPR)` for the printer, where the local
function `%` writes a register the way the dump wants it."
  (let* ((specs (mapcar #'slot-spec slots))
         (names (mapcar #'first specs))
         (def (first (slots-with-role specs :def)))
         (singles (slots-with-role specs :use))
         (lists (slots-with-role specs :uses))
         (required (loop for (n nil nil optionalp) in specs unless optionalp collect n))
         (optional (loop for (n nil d optionalp) in specs when optionalp collect (list n d)))
         (guard (or (second (assoc :reads-when clauses)) t))
         (effect (assoc :effect clauses))
         (shown (second (assoc :show clauses)))
         ;; `%` belongs to whoever wrote the `:show` clause, which may be
         ;; another package -- `mach` defines an instruction with this too.
         (% (intern "%" (symbol-package name))))
    `(progn
       (defclass ,name (instr)
         ,(loop for (slot-name nil default) in specs
                collect `(,slot-name :initarg ,(intern (string slot-name) :keyword)
                                     :initform ,default
                                     :accessor ,slot-name)))

       (defun ,name (,@required ,@(when optional `(&optional ,@optional)))
         (make-instance ',name
                        ,@(loop for n in names
                                append (list (intern (string n) :keyword) n))))

       ,@(when def
           `((defmethod defs ((i ,name)) (slot-value i ',def))
             (defmethod (setf defs) (reg (i ,name)) (setf (slot-value i ',def) reg))))

       ,@(when (or singles lists)
           `((defmethod uses ((i ,name))
               (with-slots ,names i
                 (declare (ignorable ,@names))
                 (if ,guard
                     (append (remove nil (list ,@singles))
                             ,@(mapcar (lambda (l) `(copy-list ,l)) lists))
                     '())))
             (defmethod map-uses ((i ,name) f)
               (with-slots ,names i
                 (declare (ignorable ,@names))
                 (when ,guard
                   ,@(loop for s in singles
                           collect `(when ,s (setf ,s (funcall f ,s))))
                   ,@(loop for l in lists
                           collect `(setf ,l (mapcar f ,l))))
                 nil))))

       ,@(when effect
           `((defmethod has-effect-p ((i ,name))
               (with-slots ,names i
                 (declare (ignorable ,@names))
                 ,(if (rest effect) (second effect) t)))))

       ,@(when shown
           `((defmethod show ((i ,name) namer)
               (with-slots ,names i
                 (declare (ignorable ,@names))
                 (flet ((,% (r) (funcall namer r)))
                   (declare (ignorable (function ,%)))
                   ,shown)))))
       ',name)))

;; -- the three-address instructions -------------------------------------------

(define-instr i-const ((dst :def) value)
  (:show (format nil "~A = ~D" (% dst) value)))

(define-instr i-str-const ((dst :def) symbol-of)
  (:show (format nil "~A = &~A" (% dst) symbol-of)))

(define-instr i-move ((dst :def) (src :use))
  (:show (format nil "~A = ~A" (% dst) (% src))))

(define-instr i-bin ((dst :def) op (lhs :use) (rhs :use))
  (:show (format nil "~A = ~A ~A ~A" (% dst) (% lhs) op (% rhs))))

(define-instr i-cmp ((dst :def) op (lhs :use) (rhs :use))
  (:show (format nil "~A = ~A ~A ~A" (% dst) (% lhs) op (% rhs))))

(define-instr i-load ((dst :def) (base :use) offset)
  (:show (format nil "~A = [~A + ~D]" (% dst) (% base) offset)))

(define-instr i-store ((base :use) offset (src :use))
  (:effect)
  (:show (format nil "[~A + ~D] = ~A" (% base) offset (% src))))

;; -- the frame, calls and joins, which both instruction sets keep -------------

(define-instr i-load-slot ((dst :def) slot)
  (:show (format nil "~A = slot~D" (% dst) slot)))

(define-instr i-store-slot (slot (src :use))
  (:effect)
  (:show (format nil "slot~D = ~A" slot (% src))))

(define-instr i-frame-addr ((dst :def))
  (:show (format nil "~A = frame" (% dst))))

(define-instr i-call ((dst :def) callee (args :uses))
  (:effect)
  (:show (let ((written (format nil "~A(~{~A~^, ~})" callee (mapcar #'% args))))
           (if dst (format nil "~A = ~A" (% dst) written) written))))

(define-instr i-phi ((dst :def) args)
  (:show (format nil "~A = phi [~{~A~^, ~}]"
                 (% dst)
                 (loop for (pred . reg) in args
                       collect (format nil "~A: ~A" pred (% reg))))))

;; -- control flow -------------------------------------------------------------

(define-instr i-jmp (target)
  (:effect)
  (:show (format nil "jmp ~A" target)))

(define-instr i-cbr ((test :use) then els (code :plain ""))
  ;; After selection a branch may read the flags a comparison just set instead
  ;; of testing a register, and then it reads no register at all.
  (:reads-when (string= code ""))
  (:effect)
  (:show (format nil "br ~A ~A : ~A"
                 (if (string= code "")
                     (format nil "~A ?" (% test))
                     (format nil "~A?" code))
                 then els)))

(define-instr i-ret ((value :use))
  (:effect)
  (:show (if value (format nil "ret ~A" (% value)) "ret")))

(defun terminator-p (i) (typep i '(or i-jmp i-cbr i-ret)))

;; -- a phi's arguments, which are an ordered list of edges --------------------
;;
;; The order is the order they are printed in, so it is a list of pairs and not
;; a hash table: a phi names its predecessors in the order the graph gave them,
;; and splitting an edge moves one to the end.

(defun phi-args-from (preds reg)
  (loop for p in preds collect (cons p reg)))

(defun phi-arg (phi pred)
  (cdr (assoc pred (args phi) :test #'string=)))

(defun set-phi-arg (phi pred reg)
  (let ((found (assoc pred (args phi) :test #'string=)))
    (if found
        (setf (cdr found) reg)
        (setf (args phi) (append (args phi) (list (cons pred reg)))))
    reg))

(defun remove-phi-arg (phi pred)
  (setf (args phi) (remove pred (args phi) :key #'car :test #'string=)))

(defun rename-phi-pred (phi old new)
  "Take OLD out and put NEW on the end, which is where a split edge belongs."
  (let ((found (assoc old (args phi) :test #'string=)))
    (when found
      (remove-phi-arg phi old)
      (setf (args phi) (append (args phi) (list (cons new (cdr found))))))))

(defun keep-phi-args (phi keep)
  (setf (args phi)
        (remove-if-not (lambda (pair) (member (car pair) keep :test #'string=))
                       (args phi))))

(defun map-phi-args (phi f)
  (setf (args phi)
        (loop for (pred . reg) in (args phi) collect (cons pred (funcall f reg)))))

(defun phi-preds (phi) (mapcar #'car (args phi)))
(defun phi-regs (phi) (mapcar #'cdr (args phi)))

;; -- the graph ----------------------------------------------------------------

(defstruct (basic-block (:constructor make-block (label))
                        (:conc-name block-)
                        (:copier nil))
  label
  (phis '())
  (instrs '())
  (preds '()))

(defun terminator (b)
  (let ((last (car (last (block-instrs b)))))
    (assert last () "block ~A is unterminated" (block-label b))
    (assert (terminator-p last) () "block ~A falls through" (block-label b))
    last))

(defun set-terminator (b instr)
  (setf (block-instrs b) (append (butlast (block-instrs b)) (list instr))))

(defun succs (b)
  (let ((term (terminator b)))
    (etypecase term
      (i-jmp (list (target term)))
      (i-cbr (if (string= (then term) (els term))
                 (list (then term))
                 (list (then term) (els term))))
      (i-ret '()))))

(defstruct (func (:constructor %make-func) (:copier nil))
  "One function: a frame, a set of parameters, and a graph of blocks."
  (label "" :type string)
  (name "" :type string)
  (params '())
  (depth 0)
  (entry "entry")
  (blocks (make-hash-table :test #'equal))
  (order '())
  (nregs 0)
  (nslots 0)
  (static-link-slot -1)
  (colours (make-hash-table :test #'eql))
  (spill-slots (make-hash-table :test #'eql))
  (saved '()))

(defun new-func (label name depth)
  (%make-func :label label :name name :depth depth))

(defun new-reg (f)
  (prog1 (func-nregs f) (incf (func-nregs f))))

(defun new-slot (f)
  (prog1 (func-nslots f) (incf (func-nslots f))))

(defun add-block (f label)
  (assert (not (gethash label (func-blocks f))))
  (let ((b (make-block label)))
    (setf (gethash label (func-blocks f)) b)
    (setf (func-order f) (nconc (func-order f) (list label)))
    b))

(defun block-of (f label) (gethash label (func-blocks f)))

(defun walk (f)
  (loop for label in (func-order f) collect (block-of f label)))

(defstruct (module (:constructor make-module ()) (:copier nil))
  (funcs '())
  (strings '()))   ; an ordered list of (symbol . text)

(defun add-string (m symbol text)
  (setf (module-strings m) (nconc (module-strings m) (list (cons symbol text)))))

;; -- rewriting the graph ------------------------------------------------------

(defgeneric rename-target (instr old new)
  (:method ((i instr) old new) (declare (ignore old new)) nil))

(defmethod rename-target ((i i-jmp) old new)
  (when (string= (target i) old) (setf (target i) new)))

(defmethod rename-target ((i i-cbr) old new)
  (when (string= (then i) old) (setf (then i) new))
  (when (string= (els i) old) (setf (els i) new)))

(defun recompute-preds (f)
  (dolist (b (walk f)) (setf (block-preds b) '()))
  (dolist (b (walk f))
    (dolist (s (succs b))
      (let ((target (block-of f s)))
        (setf (block-preds target)
              (nconc (block-preds target) (list (block-label b))))))))

(defun reachable (f)
  (let ((seen '()) (stack (list (func-entry f))))
    (loop while stack
          do (let ((label (pop stack)))
               (unless (member label seen :test #'string=)
                 (push label seen)
                 (setf stack (append (succs (block-of f label)) stack)))))
    seen))

(defun drop-unreachable (f)
  (let ((live (reachable f)))
    (dolist (label (func-order f))
      (unless (member label live :test #'string=)
        (remhash label (func-blocks f))))
    (setf (func-order f)
          (remove-if-not (lambda (l) (member l live :test #'string=)) (func-order f)))
    (dolist (b (walk f))
      (dolist (phi (block-phis b)) (keep-phi-args phi live)))
    (recompute-preds f)))

(defun rpo (f)
  "Reverse post-order, which is the order every dataflow pass walks in."
  (let ((order '()) (seen '()) (stack (list (cons (func-entry f) nil))))
    (loop while stack
          do (destructuring-bind (label . done) (pop stack)
               (cond
                 (done (push label order))
                 ((member label seen :test #'string=))
                 (t
                  (push label seen)
                  (push (cons label t) stack)
                  (dolist (s (reverse (succs (block-of f label))))
                    (unless (member s seen :test #'string=)
                      (push (cons s nil) stack)))))))
    ;; `order` is post-order reversed already, because it was pushed.
    order))

;; -- printing -----------------------------------------------------------------

(defun reg-name (f r)
  (let ((colour (gethash r (func-colours f))))
    (if colour (format nil "%~D:~D" r colour) (format nil "%~D" r))))

(defun naming (f) (lambda (r) (reg-name f r)))

(defun show-instr (f i) (show i (naming f)))

(defun show-func (f)
  (with-output-to-string (out)
    (format out "fun ~A(~{~A~^, ~})  ; depth ~D, ~D slots"
            (func-label f)
            (loop for r in (func-params f) collect (reg-name f r))
            (func-depth f) (func-nslots f))
    (dolist (b (walk f))
      (format out "~%~A:~@[  ; preds: ~{~A~^, ~}~]"
              (block-label b) (block-preds b))
      (dolist (phi (block-phis b)) (format out "~%    ~A" (show-instr f phi)))
      (dolist (i (block-instrs b)) (format out "~%    ~A" (show-instr f i))))))

(defun show-module (m)
  (let ((parts (loop for f in (module-funcs m) collect (show-func f))))
    (when (module-strings m)
      (setf parts
            (append parts
                    (list (format nil "~{~A~^~%~}"
                                  (loop for (sym . text) in (module-strings m)
                                        collect (format nil "~A: \"~A\"" sym text)))))))
    (format nil "~{~A~^~%~%~}~%" parts)))

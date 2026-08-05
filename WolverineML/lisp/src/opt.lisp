;;;; Optimisation on SSA.
;;;;
;;;; Five small passes run to a fixed point.  Each is cheap because SSA makes
;;;; it cheap: a register has one definition, so constant folding and copy
;;;; propagation are a lookup rather than a dataflow problem, and a phi whose
;;;; arguments all agree is a copy that was never needed.
;;;;
;;;;     fold constants   ->  arithmetic on known values
;;;;     propagate copies ->  `i-move`, and phis that turned into one
;;;;     simplify phis    ->  a phi with one distinct argument is that argument
;;;;     fold branches    ->  a branch on a known value, and the blocks it strands
;;;;     dead code        ->  anything computed and not used

(defpackage #:wolv.opt
  (:use #:cl)
  (:local-nicknames (#:ir #:wolv.ir)
                    (#:i64 #:wolv.i64))
  (:export #:optimise #:optimise-func
           #:fold-constants #:propagate-copies #:simplify-phis
           #:fold-branches #:dead-code))

(in-package #:wolv.opt)

(defun optimise (m)
  (dolist (f (ir:module-funcs m)) (optimise-func f)))

(defun optimise-func (f)
  ;; Every pass runs every round: they are cheap, and one enables another.
  (loop for changes = (mapcar (lambda (pass) (funcall pass f))
                              (list #'fold-constants #'propagate-copies
                                    #'simplify-phis #'fold-branches #'dead-code))
        until (notany #'identity changes)))

;; -- rewriting ----------------------------------------------------------------

(defun rewrite (f mapping)
  "Replace registers everywhere they are read, phi arguments included."
  (when (plusp (hash-table-count mapping))
    (labels ((resolve (r)
               (let ((seen '()))
                 (loop while (and (nth-value 1 (gethash r mapping))
                                  (not (member r seen)))
                       do (push r seen)
                          (setf r (gethash r mapping)))
                 r)))
      (dolist (b (ir:walk f))
        (dolist (phi (ir:block-phis b)) (ir:map-phi-args phi #'resolve))
        (dolist (i (ir:block-instrs b)) (ir:map-uses i #'resolve))))))

(defun constants (f)
  (let ((known (make-hash-table :test #'eql)))
    (dolist (b (ir:walk f) known)
      (dolist (i (ir:block-instrs b))
        (when (typep i 'ir:i-const)
          (setf (gethash (ir:dst i) known) (ir:value i)))))))

;; -- the passes ---------------------------------------------------------------

(defun fold-constants (f)
  (let ((known (constants f))
        (changed nil))
    (dolist (b (ir:walk f) changed)
      (setf (ir:block-instrs b)
            (loop for i in (ir:block-instrs b)
                  collect (let ((folded (fold-one i known)))
                            (cond
                              ((null folded) i)
                              (t
                               (when (typep folded 'ir:i-const)
                                 (setf (gethash (ir:dst folded) known) (ir:value folded)))
                               (setf changed t)
                               folded))))))))

(defgeneric fold-one (instr known)
  (:method ((i ir:instr) known) (declare (ignore known)) nil))

(defmethod fold-one ((i ir:i-bin) known)
  (let ((a (gethash (ir:lhs i) known))
        (b (gethash (ir:rhs i) known))
        (op (ir:op i)))
    (cond
      ((and a b)
       (let ((value (arith op a b)))
         (and value (ir:i-const (ir:dst i) value))))
      ((and b (= b 0) (member op '("+" "-" "or" "xor" "shl" "shr") :test #'string=))
       (ir:i-move (ir:dst i) (ir:lhs i)))
      ((and b (= b 1) (member op '("*" "/") :test #'string=))
       (ir:i-move (ir:dst i) (ir:lhs i)))
      ((and a (= a 0) (string= op "+"))
       (ir:i-move (ir:dst i) (ir:rhs i)))
      (t nil))))

(defmethod fold-one ((i ir:i-cmp) known)
  (let ((a (gethash (ir:lhs i) known))
        (b (gethash (ir:rhs i) known)))
    (when (and a b)
      (ir:i-const (ir:dst i) (if (order (ir:op i) a b) 1 0)))))

(defun arith (op a b)
  (cond
    ((string= op "+") (i64:add a b))
    ((string= op "-") (i64:sub a b))
    ((string= op "*") (i64:mul a b))
    ((string= op "/") (unless (zerop b) (i64:quot a b)))
    ((string= op "mod") (unless (zerop b) (i64:remainder a b)))
    ((string= op "and") (i64:bits-and a b))
    ((string= op "or") (i64:bits-or a b))
    ((string= op "xor") (i64:bits-xor a b))
    ((string= op "shl") (i64:shl a b))
    ((string= op "shr") (i64:shr a b))
    (t nil)))

(defun order (op a b)
  (cond
    ((string= op "=") (= a b))
    ((string= op "<>") (/= a b))
    ((string= op "<") (< a b))
    ((string= op "<=") (<= a b))
    ((string= op ">") (> a b))
    ((string= op ">=") (>= a b))
    ((string= op "u<") (< (i64:unsigned a) (i64:unsigned b)))
    ((string= op "u>=") (>= (i64:unsigned a) (i64:unsigned b)))
    (t (error "unknown comparison ~A" op))))

(defun propagate-copies (f)
  (let ((mapping (make-hash-table :test #'eql)))
    (dolist (b (ir:walk f))
      (dolist (i (ir:block-instrs b))
        (when (typep i 'ir:i-move)
          (setf (gethash (ir:dst i) mapping) (ir:src i)))))
    (when (zerop (hash-table-count mapping))
      (return-from propagate-copies nil))
    (rewrite f mapping)
    (dolist (b (ir:walk f))
      (setf (ir:block-instrs b)
            (remove-if (lambda (i) (typep i 'ir:i-move)) (ir:block-instrs b))))
    t))

(defun simplify-phis (f)
  (let ((mapping (make-hash-table :test #'eql))
        (changed nil))
    (dolist (b (ir:walk f))
      (setf (ir:block-phis b)
            (loop for phi in (ir:block-phis b)
                  for others = (remove-duplicates
                                (remove (ir:dst phi) (ir:phi-regs phi)))
                  if (= (length others) 1)
                    do (setf (gethash (ir:dst phi) mapping) (first others)
                             changed t)
                  else collect phi)))
    (when changed (rewrite f mapping))
    changed))

(defun fold-branches (f)
  (let ((known (constants f))
        (changed nil))
    (dolist (b (ir:walk f))
      (let ((term (ir:terminator b)))
        (when (typep term 'ir:i-cbr)
          (let ((value (gethash (ir:test term) known)))
            (when (or value (string= (ir:then term) (ir:els term)))
              (let ((taken (if (or (null value) (/= value 0))
                               (ir:then term)
                               (ir:els term))))
                (ir:set-terminator b (ir:i-jmp taken))
                (setf changed t)))))))
    (when changed (ir:drop-unreachable f))
    changed))

(defun dead-code (f)
  (let ((changed nil))
    (loop
      (let ((used (make-hash-table :test #'eql))
            (round-changed nil))
        (dolist (b (ir:walk f))
          (dolist (phi (ir:block-phis b))
            (dolist (r (ir:phi-regs phi)) (setf (gethash r used) t)))
          (dolist (i (ir:block-instrs b))
            (dolist (r (ir:uses i)) (setf (gethash r used) t))))
        (dolist (b (ir:walk f))
          (let ((phis (remove-if-not (lambda (p) (gethash (ir:dst p) used))
                                     (ir:block-phis b))))
            (unless (= (length phis) (length (ir:block-phis b)))
              (setf (ir:block-phis b) phis)
              (setf round-changed t)))
          (setf (ir:block-instrs b)
                (loop for i in (ir:block-instrs b)
                      for d = (ir:defs i)
                      if (and d (not (gethash d used)) (not (ir:has-effect-p i)))
                        do (setf round-changed t)
                      else collect i)))
        (unless round-changed (return changed))
        (setf changed t)))))

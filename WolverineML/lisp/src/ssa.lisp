;;;; SSA construction, the textbook way.
;;;;
;;;; Dominators by the iterative algorithm of Cooper, Harvey and Kennedy,
;;;; dominance frontiers from those, phis at the frontiers of every definition,
;;;; and then one walk of the dominator tree renaming as it goes.  This is
;;;; minimal SSA and nothing cleverer: a phi is placed wherever the frontier
;;;; says, whether or not the variable is live there, and the dead ones leave
;;;; in `opt:dead-code`.
;;;;
;;;; Only registers written more than once take part.  Everything lowering
;;;; produced once -- a temporary -- is already in SSA and is left with the
;;;; name it has.

(defpackage #:wolv.ssa
  (:use #:cl)
  (:local-nicknames (#:ir #:wolv.ir))
  (:export #:dominance #:dominance-idom #:dominance-children
           #:dominance-frontier #:dominance-order #:dominates-p
           #:construct #:construct-module #:split-critical-edges #:verify))

(in-package #:wolv.ssa)

(defstruct (dominance (:constructor %make-dominance (idom children frontier order))
                      (:copier nil))
  idom children frontier order)

(defun dominates-p (dom a b)
  (loop
    (when (string= a b) (return t))
    (let ((parent (gethash b (dominance-idom dom))))
      (when (string= parent b) (return nil))
      (setf b parent))))

(defun dominance (f)
  (let* ((order (ir:rpo f))
         (rank (make-hash-table :test #'equal))
         (idom (make-hash-table :test #'equal)))
    (loop for label in order for i from 0 do (setf (gethash label rank) i))
    (setf (gethash (ir:func-entry f) idom) (ir:func-entry f))

    (flet ((intersect (a b)
             (loop until (string= a b)
                   do (loop while (> (gethash a rank) (gethash b rank))
                            do (setf a (gethash a idom)))
                      (loop while (> (gethash b rank) (gethash a rank))
                            do (setf b (gethash b idom))))
             a))
      (loop with changed = t
            while changed
            do (setf changed nil)
               (dolist (label (rest order))
                 (let ((preds (remove-if-not (lambda (p) (gethash p idom))
                                             (ir:block-preds (ir:block-of f label)))))
                   (when preds
                     (let ((new (first preds)))
                       (dolist (p (rest preds)) (setf new (intersect p new)))
                       (unless (equal (gethash label idom) new)
                         (setf (gethash label idom) new)
                         (setf changed t))))))))

    (let ((children (make-hash-table :test #'equal))
          (frontier (make-hash-table :test #'equal)))
      (dolist (label order)
        (setf (gethash label children) '())
        (setf (gethash label frontier) '()))
      (dolist (label order)
        (let ((parent (gethash label idom)))
          (unless (string= parent label)
            (setf (gethash parent children)
                  (nconc (gethash parent children) (list label))))))
      (dolist (label order)
        (let ((b (ir:block-of f label)))
          (when (>= (length (ir:block-preds b)) 2)
            (dolist (pred (ir:block-preds b))
              (loop with runner = pred
                    while (and (not (string= runner (gethash label idom)))
                               (gethash runner idom))
                    do (pushnew label (gethash runner frontier) :test #'string=)
                       (setf runner (gethash runner idom)))))))
      (%make-dominance idom children frontier order))))

;; -- where each register is written -------------------------------------------
;;
;; A register written twice in one block is as much a variable as one written
;; in two blocks, so the count is what decides, and the blocks are what the
;; frontier walk needs.

(defstruct (defs-of (:constructor make-defs-of ()) (:copier nil))
  (blocks (make-hash-table :test #'eql))
  (count (make-hash-table :test #'eql)))

(defun note-def (d r label)
  (pushnew label (gethash r (defs-of-blocks d)) :test #'string=)
  (incf (gethash r (defs-of-count d) 0)))

(defun definitions (f)
  (let ((d (make-defs-of)))
    (dolist (b (ir:walk f))
      (dolist (i (ir:block-instrs b))
        (let ((r (ir:defs i)))
          (when r (note-def d r (ir:block-label b))))))
    (dolist (p (ir:func-params f))
      (note-def d p (ir:func-entry f)))
    d))

(defun variables (d)
  (sort (loop for r being the hash-keys of (defs-of-count d)
                using (hash-value n)
              when (> n 1) collect r)
        #'<))

;; -- placing the phis ---------------------------------------------------------

(defun place-phis (f dom d)
  "Put a phi for each variable at every dominance frontier of a block defining it."
  (let ((phi-vars (make-hash-table :test #'equal)))
    (dolist (label (ir:func-order f)) (setf (gethash label phi-vars) '()))
    (dolist (v (variables d))
      (let* ((sites (gethash v (defs-of-blocks d)))
             (placed '())
             ;; A stack whose top is the front, which is where the last
             ;; frontier block found is put back.
             (work (reverse (sort (copy-list sites) #'string<))))
        (loop while work
              do (let ((b (pop work)))
                   (dolist (target (sort (copy-list (gethash b (dominance-frontier dom)))
                                         #'string<))
                     (unless (member target placed :test #'string=)
                       (push target placed)
                       (setf (gethash target phi-vars)
                             (nconc (gethash target phi-vars) (list v)))
                       (let ((block* (ir:block-of f target)))
                         (setf (ir:block-phis block*)
                               (nconc (ir:block-phis block*)
                                      (list (ir:i-phi
                                             v (ir:phi-args-from (ir:block-preds block*) v))))))
                       (unless (member target sites :test #'string=)
                         (push target work))))))))
    phi-vars))

;; -- renaming -----------------------------------------------------------------

(defclass renamer ()
  ((func :initarg :func :reader func)
   (dom :initarg :dom :reader dom)
   (phi-vars :initarg :phi-vars :reader phi-vars)
   (variables :initarg :variables :reader vars)   ; a set, as a hash table
   (stacks :initform (make-hash-table :test #'eql) :reader stacks)
   (undefined :initform (make-hash-table :test #'eql) :reader undefined)
   (undefined-order :initform '() :accessor undefined-order)))

(defun variable-p (rn v) (gethash v (vars rn)))

(defun variable-set (d)
  (let ((set (make-hash-table :test #'eql)))
    (dolist (r (variables d) set) (setf (gethash r set) t))))

(defun undef (rn v)
  "A variable read on a path that never wrote it reads zero."
  (or (gethash v (undefined rn))
      (let ((r (ir:new-reg (func rn))))
        (setf (gethash v (undefined rn)) r)
        (setf (undefined-order rn) (nconc (undefined-order rn) (list r)))
        r)))

(defun top-of (rn v)
  (let ((stack (gethash v (stacks rn))))
    (if stack (first stack) (undef rn v))))

(defun rename-def (rn v)
  (let ((fresh (ir:new-reg (func rn))))
    (push fresh (gethash v (stacks rn)))
    fresh))

(defun plant-undefined (rn)
  (let ((entry (ir:block-of (func rn) (ir:func-entry (func rn)))))
    (dolist (r (undefined-order rn))
      (push (ir:i-const r 0) (ir:block-instrs entry)))))

(defun rename-block (rn label)
  (let* ((f (func rn))
         (b (ir:block-of f label))
         (mine '()))
    (loop for phi in (ir:block-phis b)
          for v in (gethash label (phi-vars rn))
          do (setf (ir:defs phi) (rename-def rn v))
             (push v mine))
    (dolist (i (ir:block-instrs b))
      (ir:map-uses i (lambda (r) (if (variable-p rn r) (top-of rn r) r)))
      (let ((d (ir:defs i)))
        (when (and d (variable-p rn d))
          (setf (ir:defs i) (rename-def rn d))
          (push d mine))))
    (dolist (succ (ir:succs b))
      (loop for phi in (ir:block-phis (ir:block-of f succ))
            for v in (gethash succ (phi-vars rn))
            do (ir:set-phi-arg phi label (top-of rn v))))
    (nreverse mine)))

(defun run-renamer (rn)
  (let ((work (list (cons (ir:func-entry (func rn)) nil)))
        (pushed (make-hash-table :test #'equal)))
    (loop while work
          do (destructuring-bind (label . done) (pop work)
               (if done
                   (dolist (v (gethash label pushed)) (pop (gethash v (stacks rn))))
                   (progn
                     (setf (gethash label pushed) (rename-block rn label))
                     (push (cons label t) work)
                     (dolist (child (reverse (gethash label (dominance-children (dom rn)))))
                       (push (cons child nil) work))))))))

(defun construct (f)
  "Rewrite one function into SSA, in place."
  (ir:recompute-preds f)
  (let* ((dom (dominance f))
         (d (definitions f))
         (phi-vars (place-phis f dom d))
         (rn (make-instance 'renamer :func f :dom dom :phi-vars phi-vars
                                     :variables (variable-set d))))
    (setf (ir:func-params f)
          (loop for p in (ir:func-params f)
                collect (if (variable-p rn p) (rename-def rn p) p)))
    (run-renamer rn)
    (plant-undefined rn)))

(defun construct-module (m)
  (dolist (f (ir:module-funcs m)) (construct f)))

;; -- giving every phi a place to put its copy in ------------------------------

(defun split-critical-edges (f)
  "An edge from a block with several successors into a block with several
predecessors has nowhere to hold the copies a phi turns into, so it gets a
block of its own.  The same goes for any edge into a block that still has a
phi, so that the emitter only ever has to put copies before a `jmp`."
  (dolist (label (copy-list (ir:func-order f)))
    (let ((b (ir:block-of f label)))
      (when (>= (length (ir:succs b)) 2)
        (dolist (succ (copy-list (ir:succs b)))
          (let ((target (ir:block-of f succ)))
            (unless (and (< (length (ir:block-preds target)) 2)
                         (null (ir:block-phis target)))
              (let ((split (ir:add-block f (format nil "~A.~A" label succ))))
                (setf (ir:block-instrs split) (list (ir:i-jmp succ)))
                (ir:rename-target (ir:terminator b) succ (ir:block-label split))
                (dolist (phi (ir:block-phis target))
                  (ir:rename-phi-pred phi label (ir:block-label split))))))))))
  (ir:recompute-preds f))

;; -- what SSA promises --------------------------------------------------------

(defun verify (f)
  "One definition per register, and it dominates every use."
  (let ((dom (dominance f))
        (definition (make-hash-table :test #'eql)))
    (dolist (b (ir:walk f))
      (dolist (phi (ir:block-phis b))
        (assert (not (gethash (ir:dst phi) definition)) ()
                "%~D defined twice" (ir:dst phi))
        (setf (gethash (ir:dst phi) definition) (ir:block-label b)))
      (dolist (i (ir:block-instrs b))
        (let ((d (ir:defs i)))
          (when d
            (assert (not (gethash d definition)) () "%~D defined twice" d)
            (setf (gethash d definition) (ir:block-label b))))))
    (dolist (p (ir:func-params f))
      (unless (gethash p definition)
        (setf (gethash p definition) (ir:func-entry f))))
    (dolist (b (ir:walk f))
      (dolist (phi (ir:block-phis b))
        (assert (equal (sort (copy-list (ir:phi-preds phi)) #'string<)
                       (sort (copy-list (ir:block-preds b)) #'string<))
                () "phi in ~A names ~A, preds are ~A"
                (ir:block-label b) (ir:phi-preds phi) (ir:block-preds b))
        (loop for (pred . r) in (ir:args phi)
              do (let ((where (gethash r definition)))
                   (assert where () "%~D is never defined" r)
                   (assert (dominates-p dom where pred) ()
                           "%~D does not reach ~A through ~A" r (ir:block-label b) pred))))
      (dolist (i (ir:block-instrs b))
        (dolist (r (ir:uses i))
          (let ((where (gethash r definition)))
            (assert where () "%~D is never defined" r)
            (assert (dominates-p dom where (ir:block-label b)) ()
                    "%~D does not dominate its use in ~A" r (ir:block-label b))))))))

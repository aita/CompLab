;;;; Doing several copies at once, one at a time.
;;;;
;;;; A phi is a copy that happens on an edge, and all the phis of a block
;;;; happen together: every argument is read before any destination is written.
;;;; Once the allocator has given both ends real registers that is a
;;;; permutation, and putting a permutation into a sequence of instructions is
;;;; this module.
;;;;
;;;; Copies whose destination nobody else has still to read can go first.  When
;;;; only cycles are left, something has to be got out of the way, and there
;;;; are two ways to do it: a register the function never used can hold a value
;;;; for one step, and if there is no such register the two ends of the cycle
;;;; swap.  A swap is three `eor`s and needs nothing to borrow, which is why no
;;;; register is reserved for this anywhere in the compiler.

(defpackage #:wolv.copies
  (:use #:cl)
  (:export #:mov #:mov-p #:mov-dst #:mov-src
           #:swap #:swap-p #:swap-a #:swap-b
           #:sequentialize))

(in-package #:wolv.copies)

(defstruct (mov (:constructor mov (dst src)) (:copier nil)) dst src)
(defstruct (swap (:constructor swap (a b)) (:copier nil)) a b)

(defun sequentialize (moves borrowed)
  "Order (DESTINATION . SOURCE) pairs so that nothing is lost on the way.

MOVES keeps its order, because which copy goes first is visible in the
assembly, so `pending` below is an association list and not a hash table."
  (let ((pending (remove-if (lambda (m) (eql (car m) (cdr m)))
                            (mapcar (lambda (m) (cons (car m) (cdr m))) moves)))
        (done '()))
    (assert (= (length pending)
               (length (remove-duplicates pending :key #'car)))
            () "a parallel copy writes a register twice")
    (loop while pending
          do (let* ((sources (mapcar #'cdr pending))
                    (ready (loop for (dst . nil) in pending
                                 unless (cl:member dst sources) collect dst)))
               (cond
                 (ready
                  (dolist (dst ready)
                    (push (mov dst (cdr (assoc dst pending))) done)
                    (setf pending (remove dst pending :key #'car))))
                 (t
                  (let ((stuck (car (first pending))))
                    (cond
                      (borrowed
                       (push (mov borrowed stuck) done)
                       (setf pending (moved pending stuck borrowed)))
                      (t
                       ;; Swapping satisfies `stuck` outright and leaves its old
                       ;; value where the other end was, so everything still to
                       ;; read it reads there instead.
                       (let ((other (cdr (assoc stuck pending))))
                         (setf pending (remove stuck pending :key #'car))
                         (push (swap stuck other) done)
                         (setf pending (moved pending stuck other))))))))))
    (nreverse done)))

(defun moved (pending was now)
  "The value that was in WAS is in NOW; whoever wanted it looks there."
  (loop for (dst . src) in pending
        unless (and (eql src was) (eql dst now))   ; a swap already put it there
          collect (cons dst (if (eql src was) now src))))

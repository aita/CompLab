;;;; Spilling.
;;;;
;;;; A spilled value gets a frame slot, a store after every definition of it
;;;; and a reload in front of every use.  The reloads are new registers, live
;;;; from the load to the instruction under it and nowhere else, which is what
;;;; makes the pressure come down.  Nothing here assumes SSA: a value written
;;;; twice gets two stores, and a phi argument is reloaded at the end of the
;;;; predecessor it comes from.

(defpackage #:wolv.spill
  (:use #:cl)
  (:local-nicknames (#:ir #:wolv.ir)
                    (#:ssa #:wolv.ssa))
  (:export #:out-of-registers #:out-of-registers-message
           #:loop-depth #:costs #:spill))

(in-package #:wolv.spill)

(define-condition out-of-registers (error)
  ((message :initarg :message :reader out-of-registers-message))
  (:report (lambda (c stream) (write-string (out-of-registers-message c) stream)))
  (:documentation "Signalled when spilling cannot help either."))

(defun loop-depth (f)
  "How deeply each block is nested in loops, for weighing what a use costs.

A back edge is an edge into a block that dominates its source; everything that
can reach the source without leaving the dominated region is in that loop."
  (let ((dom (ssa:dominance f))
        (depth (make-hash-table :test #'equal)))
    (dolist (label (ir:func-order f)) (setf (gethash label depth) 0))
    (dolist (b (ir:walk f) depth)
      (dolist (succ (ir:succs b))
        (when (ssa:dominates-p dom succ (ir:block-label b))
          (let ((body (list succ))
                (stack (list (ir:block-label b))))
            (loop while stack
                  do (let ((label (pop stack)))
                       (unless (cl:member label body :test #'string=)
                         (push label body)
                         (setf stack (append (ir:block-preds (ir:block-of f label))
                                             stack)))))
            (dolist (label body) (incf (gethash label depth)))))))))

(defun costs (f)
  "What spilling a value would cost: its reads and writes, weighed by loops."
  (let ((depth (loop-depth f))
        (weight (make-hash-table :test #'eql)))
    (flet ((bump (r by) (incf (gethash r weight 0d0) by)))
      (dolist (b (ir:walk f) weight)
        (let ((scale (float (expt 10 (min (gethash (ir:block-label b) depth) 4)) 1d0)))
          (dolist (phi (ir:block-phis b))
            (loop for (pred . arg) in (ir:args phi)
                  do (bump arg (float (expt 10 (min (gethash pred depth) 4)) 1d0)))
            (bump (ir:dst phi) scale))
          (dolist (i (ir:block-instrs b))
            (dolist (r (ir:uses i)) (bump r scale))
            (let ((d (ir:defs i))) (when d (bump d scale)))))))))

(defun spill (f victim)
  "Give VICTIM a frame slot, and answer with the reloads that replaced it."
  (let ((slot (ir:new-slot f))
        (is-param (cl:member victim (ir:func-params f)))
        (reloads '()))
    (setf (gethash victim (ir:func-spill-slots f)) slot)

    (dolist (b (ir:walk f))
      (when (find victim (ir:block-phis b) :key #'ir:dst)
        (push (ir:i-store-slot slot victim) (ir:block-instrs b)))
      (when (and is-param (string= (ir:block-label b) (ir:func-entry f)))
        (push (ir:i-store-slot slot victim) (ir:block-instrs b)))

      (setf (ir:block-instrs b)
            (loop for i in (ir:block-instrs b)
                  for spill-store = (and (typep i 'ir:i-store-slot) (= (ir:slot i) slot))
                  append (let ((before '()))
                           (when (and (cl:member victim (ir:uses i)) (not spill-store))
                             (let ((fresh (ir:new-reg f)))
                               (push fresh reloads)
                               (setf before (list (ir:i-load-slot fresh slot)))
                               (ir:map-uses i (lambda (r) (if (eql r victim) fresh r)))))
                           (append before
                                   (list i)
                                   (when (eql (ir:defs i) victim)
                                     (list (ir:i-store-slot slot victim))))))))

    (dolist (b (ir:walk f))
      (dolist (phi (ir:block-phis b))
        (loop for (pred . arg) in (copy-list (ir:args phi))
              do (when (eql arg victim)
                   (let ((source (ir:block-of f pred))
                         (fresh (ir:new-reg f)))
                     (push fresh reloads)
                     (setf (ir:block-instrs source)
                           (append (butlast (ir:block-instrs source))
                                   (list (ir:i-load-slot fresh slot))
                                   (last (ir:block-instrs source))))
                     (ir:set-phi-arg phi pred fresh))))))
    reloads))

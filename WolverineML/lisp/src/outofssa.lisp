;;;; Leaving SSA before allocation.
;;;;
;;;; A phi is a copy that happens on an edge, so it becomes copies at the end
;;;; of each predecessor.  Critical edges are already split, so a predecessor
;;;; of a block with phis has nowhere else to go and the copies can simply be
;;;; appended.
;;;;
;;;; The copies of one edge happen at once: every argument is read before any
;;;; destination is written.  Usually that needs no care, because a phi's
;;;; destination is defined nowhere else and so is nobody's argument -- but a
;;;; block that is its own predecessor can have two phis that swap, and then
;;;; the copies go through temporaries, which is Sreedhar's answer and which
;;;; coalescing is expected to remove again.

(defpackage #:wolv.outofssa
  (:use #:cl)
  (:local-nicknames (#:ir #:wolv.ir))
  (:export #:destruct #:destruct-module))

(in-package #:wolv.outofssa)

(defun destruct (f)
  "Replace every phi in F with copies in its predecessors."
  (dolist (b (ir:walk f))
    (when (ir:block-phis b)
      (dolist (pred (ir:block-preds b))
        (let ((source (ir:block-of f pred)))
          (assert (= (length (ir:succs source)) 1) ()
                  "~A -> ~A is a critical edge" pred (ir:block-label b))
          (copy-in-parallel f source
                            (loop for phi in (ir:block-phis b)
                                  collect (cons (ir:dst phi) (ir:phi-arg phi pred))))))
      (setf (ir:block-phis b) '())))
  (ir:recompute-preds f))

(defun destruct-module (m)
  (dolist (f (ir:module-funcs m)) (destruct f)))

(defun copy-in-parallel (f b moves)
  (let ((real (remove-if (lambda (m) (eql (car m) (cdr m))) moves)))
    (when real
      (let* ((written (mapcar #'car real))
             (read (mapcar #'cdr real))
             (copies
               (if (intersection written read)
                   ;; Something written here is also read here, so the values
                   ;; go through temporaries first.
                   (let ((through (loop for (dst . nil) in real
                                        collect (cons dst (ir:new-reg f)))))
                     (append
                      (loop for (dst . src) in real
                            collect (ir:i-move (cdr (assoc dst through)) src))
                      (loop for (dst . nil) in real
                            collect (ir:i-move dst (cdr (assoc dst through))))))
                   (loop for (dst . src) in real collect (ir:i-move dst src)))))
        (setf (ir:block-instrs b)
              (append (butlast (ir:block-instrs b))
                      copies
                      (last (ir:block-instrs b))))))))

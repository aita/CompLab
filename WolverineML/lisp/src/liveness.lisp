;;;; Liveness on SSA.
;;;;
;;;; The only subtlety is the phi.  A phi does not read its arguments where it
;;;; stands; it reads them on the edges, so an argument is live at the end of
;;;; the predecessor it is paired with and not anywhere inside the block that
;;;; holds the phi.  Getting that wrong is what makes phi-related values
;;;; interfere when they should not.

(defpackage #:wolv.liveness
  (:use #:cl)
  (:local-nicknames (#:ir #:wolv.ir)
                    (#:rs #:wolv.regset))
  (:export #:liveness #:analyse #:live-in #:live-out #:across-calls #:pressure))

(in-package #:wolv.liveness)

(defstruct (liveness (:constructor make-liveness ()) (:copier nil))
  (ins (make-hash-table :test #'equal))
  (outs (make-hash-table :test #'equal)))

(defun live-in (l label) (gethash label (liveness-ins l)))
(defun live-out (l label) (gethash label (liveness-outs l)))

(defun analyse (f)
  (let ((upward (make-hash-table :test #'equal))
        (killed (make-hash-table :test #'equal))
        (l (make-liveness)))
    (dolist (b (ir:walk f))
      (let ((use (rs:empty)) (kill (rs:empty)))
        (dolist (phi (ir:block-phis b)) (setf kill (rs:adjoin (ir:dst phi) kill)))
        (dolist (i (ir:block-instrs b))
          (dolist (r (ir:uses i))
            (unless (rs:member r kill) (setf use (rs:adjoin r use))))
          (let ((d (ir:defs i)))
            (when d (setf kill (rs:adjoin d kill)))))
        (setf (gethash (ir:block-label b) upward) use)
        (setf (gethash (ir:block-label b) killed) kill)))

    (dolist (label (ir:func-order f))
      (setf (gethash label (liveness-ins l)) (rs:empty))
      (setf (gethash label (liveness-outs l)) (rs:empty)))

    (let ((order (reverse (ir:rpo f))))
      (loop with changed = t
            while changed
            do (setf changed nil)
               (dolist (label order)
                 (let ((b (ir:block-of f label))
                       (out (rs:empty)))
                   (dolist (succ (ir:succs b))
                     (setf out (rs:union out (live-in l succ)))
                     (dolist (phi (ir:block-phis (ir:block-of f succ)))
                       (let ((arg (ir:phi-arg phi label)))
                         (when arg (setf out (rs:adjoin arg out))))))
                   (let ((new-in (rs:union (gethash label upward)
                                           (rs:set-difference out (gethash label killed)))))
                     (unless (and (rs:same out (live-out l label))
                                  (rs:same new-in (live-in l label)))
                       (setf (gethash label (liveness-outs l)) out)
                       (setf (gethash label (liveness-ins l)) new-in)
                       (setf changed t)))))))
    l))

(defun across-calls (f l)
  "Values that are live across a call, and so cannot sit in a scratch register."
  (let ((out (rs:empty)))
    (dolist (b (ir:walk f) out)
      (let ((after (live-out l (ir:block-label b))))
        (dolist (i (reverse (ir:block-instrs b)))
          (let ((d (ir:defs i)))
            (when d (setf after (rs:remove d after)))
            (when (typep i 'ir:i-call) (setf out (rs:union out after)))
            (setf after (rs:union after (rs:from-list (ir:uses i))))))))))

(defun pressure (f l)
  "The most values live at any one point -- the registers the function wants."
  (loop for b in (ir:walk f) maximize (block-pressure b l)))

(defun block-pressure (b l)
  (let ((after (live-out l (ir:block-label b))))
    (max (rs:count after)
         (loop for i in (reverse (ir:block-instrs b))
               do (let ((d (ir:defs i)))
                    (when d (setf after (rs:remove d after)))
                    (setf after (rs:union after (rs:from-list (ir:uses i)))))
               maximize (rs:count after))
         (rs:count (rs:union (live-in l (ir:block-label b))
                             (rs:from-list (mapcar #'ir:dst (ir:block-phis b))))))))

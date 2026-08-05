;;;; Which colour a value would like, which is the calling convention asking.
;;;;
;;;; The allocator does not have to satisfy these -- a preference is dropped
;;;; the moment it clashes with something the colouring actually requires --
;;;; but taking one when it is free is what stops the emitter having to move a
;;;; value into `x2` on the way into a call, or out of `x0` on the way back
;;;; from one.

(defpackage #:wolv.hints
  (:use #:cl)
  (:local-nicknames (#:ir #:wolv.ir)
                    (#:reg #:wolv.registers))
  (:export #:preferences))

(in-package #:wolv.hints)

(defun preferences (f)
  "The register each value is about to be wanted in, where there is one."
  (let ((wanted (make-hash-table :test #'eql)))
    (loop for param in (ir:func-params f)
          for colour in reg:*argument-regs*
          do (setf (gethash param wanted) colour))
    (dolist (b (ir:walk f) wanted)
      (dolist (i (ir:block-instrs b))
        (typecase i
          (ir:i-call
           (loop for arg in (ir:args i)
                 for colour in reg:*argument-regs*
                 do (setf (gethash arg wanted) colour))
           (when (ir:dst i)
             (setf (gethash (ir:dst i) wanted) (first reg:*argument-regs*))))
          (ir:i-ret
           (when (ir:value i)
             (setf (gethash (ir:value i) wanted) (first reg:*argument-regs*)))))))))

;;;; The register allocator, and the verifier it answers to.
;;;;
;;;; The Python tree has two of these -- one that colours the SSA program
;;;; itself in dominance order and one that leaves SSA first -- so that the two
;;;; can be measured against each other.  This tree keeps the second: leave
;;;; SSA, build the interference graph, and colour it with Chaitin's algorithm
;;;; and George and Appel's iterated coalescing.

(defpackage #:wolv.allocator
  (:use #:cl)
  (:local-nicknames (#:graph #:wolv.graph)
                    (#:ir #:wolv.ir)
                    (#:live #:wolv.liveness)
                    (#:reg #:wolv.registers)
                    (#:rs #:wolv.regset))
  (:export #:allocate-module #:verify))

(in-package #:wolv.allocator)

(defun allocate-module (m machine)
  (dolist (f (ir:module-funcs m)) (graph:allocate f machine)))

(defun verify (f)
  "No two values that hold different things at once may share a colour.

The check is made where the interference graph joins values -- at each
definition, and at the top of a block for the phis and the parameters, which
define several at once.  Looking at a whole live set instead would be wrong,
not merely slower: both ends of a copy are live after it and hold the same
value, so they may share a register, and that is the entire point of
coalescing.  A verifier that rejected it would reject every program the
coalescer had done its job on.

Every value that interferes with another is caught this way, because the later
of the two definitions that put the values there happens while the other is
live."
  (let ((l (live:analyse f))
        (colours (ir:func-colours f)))
    (dolist (b (ir:walk f))
      (let ((alive (live:live-out l (ir:block-label b))))
        (dolist (i (reverse (ir:block-instrs b)))
          (when (typep i 'ir:i-move) (setf alive (rs:remove (ir:src i) alive)))
          (dolist (r (ir:uses i))
            (assert (gethash r colours) () "%~D has no colour" r))
          (let ((d (ir:defs i)))
            (when d
              (assert (gethash d colours) () "%~D has no colour" d)
              (setf alive (rs:adjoin d alive))
              (no-clash f alive d (ir:block-label b))
              (setf alive (rs:remove d alive))))
          (setf alive (rs:union alive (rs:from-list (ir:uses i))))))

      (let ((entering (live:live-in l (ir:block-label b))))
        (dolist (phi (ir:block-phis b))
          (assert (gethash (ir:dst phi) colours) () "%~D has no colour" (ir:dst phi))
          (setf entering (rs:adjoin (ir:dst phi) entering))
          (no-clash f entering (ir:dst phi) (ir:block-label b)))
        (when (string= (ir:block-label b) (ir:func-entry f))
          (dolist (param (ir:func-params f))
            (setf entering (rs:adjoin param entering))
            (no-clash f entering param (ir:block-label b))))))))

(defun no-clash (f alive written where)
  "Nothing else live here may hold the colour WRITTEN was just given."
  (let ((colour (gethash written (ir:func-colours f))))
    (when colour
      (dolist (other alive)
        (when (and (not (eql other written))
                   (eql (gethash other (ir:func-colours f)) colour))
          (error "x~D holds %~D and %~D at once in ~A"
                 colour written other where))))))

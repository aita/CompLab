;;;; Sixty-four bit arithmetic.
;;;;
;;;; Common Lisp's integers are the mathematical ones, which is the right
;;;; default and the wrong width: the language this compiles has an `int` that
;;;; is eight bytes and wraps.  So every operation the optimiser folds comes
;;;; back through `wrap`, and the shifts say for themselves what happens past
;;;; sixty-three rather than leaving it to the host.
;;;;
;;;; `truncate` and `rem` are already what `sdiv` and `msub` do -- they round
;;;; towards zero -- so the two operations that usually need care need none.

(defpackage #:wolv.i64
  (:use #:cl)
  (:export #:+width+ #:+min+ #:+max+
           #:wrap #:unsigned
           #:add #:sub #:mul #:quot #:remainder
           #:bits-and #:bits-or #:bits-xor #:shl #:shr))

(in-package #:wolv.i64)

(defconstant +width+ 64)
(defconstant +span+ (expt 2 +width+))
(defconstant +min+ (- (expt 2 (1- +width+))))
(defconstant +max+ (1- (expt 2 (1- +width+))))

(defun wrap (n)
  "The value N has once it is kept in sixty-four bits."
  (let ((m (mod n +span+)))
    (if (> m +max+) (- m +span+) m)))

(defun unsigned (n)
  "The same bits read as unsigned, which is what `u<` and `u>=` compare."
  (mod n +span+))

(defun add (a b) (wrap (+ a b)))
(defun sub (a b) (wrap (- a b)))
(defun mul (a b) (wrap (* a b)))

;; `min-int / -1` overflows, and wraps back to `min-int`.
(defun quot (a b) (wrap (truncate a b)))
(defun remainder (a b) (wrap (rem a b)))

(defun bits-and (a b) (wrap (logand (unsigned a) (unsigned b))))
(defun bits-or (a b) (wrap (logior (unsigned a) (unsigned b))))
(defun bits-xor (a b) (wrap (logxor (unsigned a) (unsigned b))))

(defun shl (a b)
  "A shift of sixty-four or more is not the host's business to decide."
  (cond ((minusp b) nil)
        ((>= b +width+) 0)
        (t (wrap (ash a b)))))

(defun shr (a b)
  (cond ((minusp b) nil)
        ((>= b +width+) (if (minusp a) -1 0))
        (t (ash a (- b)))))

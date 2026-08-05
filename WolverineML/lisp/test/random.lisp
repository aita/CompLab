;;;; Random programs, compiled and checked against what the oracle says they mean.

(defpackage #:wolv.test.random
  (:use #:cl #:wolv.test)
  (:local-nicknames (#:driver #:wolv.driver) (#:emit #:wolv.emit)
                    (#:oracle #:wolv.test.oracle)))

(in-package #:wolv.test.random)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (setf *suite* "random"))

(defparameter *configurations*
  (list (cons "default" (driver:make-options t t nil))
        (cons "no-opt" (driver:make-options t nil nil))
        (cons "spilling" (driver:make-options t t 10))))

(defun lines (&rest parts) (format nil "~{~A~^~%~}~%" parts))

;; The first line that differs is the useful part of the answer.
(defun agrees (source expected opts what)
  (let* ((done (driver:run source opts))
         (got (split-lines (driver:outcome-out done)))
         (want (split-lines expected)))
    (is= 0 (driver:outcome-status done) (driver:outcome-err done))
    (loop for g in got for w in want for i from 0
          do (is= w g (format nil "~A, line ~D" what i)))
    (is= (length want) (length got) what)))

(deftest "arithmetic"
  (if (not (driver:toolchain-ready-p))
      (skip "no ARM toolchain")
      (dolist (seed '(1 2))
        (multiple-value-bind (source expected) (oracle:arithmetic seed 25)
          (dolist (c *configurations*)
            (agrees source expected (cdr c)
                    (format nil "arithmetic ~D [~A]" seed (car c))))))))

(deftest "arrays, loops and branches"
  (when (driver:toolchain-ready-p)
    (dolist (seed '(1 2))
      (multiple-value-bind (source expected) (oracle:imperative seed 8)
        (dolist (c *configurations*)
          (agrees source expected (cdr c)
                  (format nil "imperative ~D [~A]" seed (car c))))))))

(deftest "a cycle of copies can be done without a scratch register"
  ;; The recursive call swaps its two arguments, so the copies into `x0` and
  ;; `x1` are a cycle that has to be untangled somehow.  The borrowed register
  ;; is what usually hides the other path.
  (when (driver:toolchain-ready-p)
    (let ((source (lines "fun swap (a : int, b : int) : int ="
                         "  if a > b then swap (b, a) else b * 10 + a"
                         "val () = (printInt (swap (1, 2)); print (\" \"); printInt (swap (7, 3)))")))
      (is= "21 73" (driver:outcome-out (driver:run source (driver:default-options))))
      (let ((emit:*borrow-nothing* t))
        (is (some (lambda (l) (search "eor x" l))
                  (split-lines (driver:compile-to-asm source (driver:default-options))))
            "no swap was written")
        (is= "21 73" (driver:outcome-out (driver:run source (driver:default-options))))))))

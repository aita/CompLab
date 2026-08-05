;;;; End to end: compile to ARMv8, assemble, link, and run it.
;;;;
;;;; These are the only tests that need a toolchain.  Without a cross `gcc` and
;;;; `qemu-aarch64` they say so and carry on, so the rest of the suite still
;;;; runs on a machine that has neither.

(defpackage #:wolv.test.programs
  (:use #:cl #:wolv.test)
  (:local-nicknames (#:driver #:wolv.driver)))

(in-package #:wolv.test.programs)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (setf *suite* "programs"))

(defun lines (&rest parts) (format nil "~{~A~^~%~}~%" parts))

(defparameter *configurations*
  (list (cons "default" (driver:make-options t t nil))
        (cons "no-opt" (driver:make-options t nil nil))
        (cons "no-checks" (driver:make-options nil t nil))
        (cons "spilling" (driver:make-options t t 12))
        (cons "spilling-no-opt" (driver:make-options t nil 12))))

(defun wol-files (directory)
  (sort (mapcar #'namestring (directory (tree-file (concatenate 'string directory "*.wol"))))
        #'string<))

(defun ran (source opts &optional (stdin ""))
  (let ((done (driver:run source opts stdin)))
    (is= 0 (driver:outcome-status done) (driver:outcome-err done))
    (driver:outcome-out done)))

(defun expected-output (path)
  (read-file (make-pathname :type "out" :defaults (pathname path))))

(deftest "every option gives the same answer; only the code differs"
  (if (not (driver:toolchain-ready-p))
      (skip "no ARM toolchain")
      (dolist (path (wol-files "test/programs/"))
        (let ((source (read-file path))
              (want (expected-output path)))
          (dolist (c *configurations*)
            (is= want (ran source (cdr c))
                 (format nil "~A [~A]" (pathname-name path) (car c))))))))

(deftest "the examples agree with themselves"
  ;; No expected output on file: what matters is that the stages agree.
  (when (driver:toolchain-ready-p)
    (dolist (path (wol-files "examples/"))
      (let* ((source (read-file path))
             (baseline (ran source (driver:default-options))))
        (is (plusp (length baseline)))
        (dolist (c (rest *configurations*))
          (unless (string= (car c) "no-checks")
            (is= baseline (ran source (cdr c))
                 (format nil "~A [~A]" (pathname-name path) (car c)))))))))

(deftest "the checks catch what they are for"
  (when (driver:toolchain-ready-p)
    (dolist (case* (list (cons (lines "val a = array (3, 0)" "val () = printInt (a[5])")
                               "outside an array")
                         (cons (lines "type t = { x : int }" "val n : t = nil"
                                      "val () = printInt (n.x)")
                               "field of nil")
                         (cons (lines "var z = 0" "val () = printInt (7 / z)")
                               "division by zero")))
      (let ((done (driver:run (car case*) (driver:default-options))))
        (is= 1 (driver:outcome-status done))
        (is (search (cdr case*) (driver:outcome-err done)) (cdr case*))))))

(deftest "a check can be turned off"
  (when (driver:toolchain-ready-p)
    (is= "0" (ran (lines "val a = array (3, 0)" "val () = printInt (a[1])")
                  (driver:make-options nil t nil)))))

(deftest "standard input"
  (when (driver:toolchain-ready-p)
    (let ((source (lines "var line = \"\""
                         "var c = getChar ()"
                         "val () = while c <> \"\" andalso c <> \"\\n\" do (line := line ^ c; c := getChar ())"
                         "val () = print (\"read: \" ^ line ^ \" (\" ^ intToString (size (line)) ^ \")\\n\")")))
      (is= (format nil "read: hello (5)~%")
           (ran source (driver:default-options) (format nil "hello~%"))))))

(deftest "the exit code is the program's"
  (when (driver:toolchain-ready-p)
    (let ((done (driver:run "val () = (print (\"bye\\n\"); exit (3))"
                            (driver:default-options))))
      (is= 3 (driver:outcome-status done))
      (is= (format nil "bye~%") (driver:outcome-out done)))))

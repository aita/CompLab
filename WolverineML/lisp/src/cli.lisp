;;;; The command line.
;;;;
;;;; Errors arrive as conditions, so the whole of the error handling is one
;;;; `handler-case` around the command: no pass below has to carry a failure
;;;; back to the one above it.

(defpackage #:wolv.cli
  (:use #:cl)
  (:local-nicknames (#:diag #:wolv.diag)
                    (#:driver #:wolv.driver)
                    (#:spill #:wolv.spill))
  (:export #:main #:toplevel))

(in-package #:wolv.cli)

(defparameter *usage*
  "wolv -- compile WolverineML to ARMv8

  wolv build  FILE [-o OUT]   build an executable
  wolv run    FILE            build it and run it
  wolv check  FILE            typecheck only
  wolv emit   FILE [-s STAGE] dump one stage

  -s, --stage STAGE   one of: tokens ast ir ssa opt dag mach flat ra asm
  --no-checks         leave out the nil, bounds and divide-by-zero checks
  --no-opt            do not optimise the SSA
  --max-regs N        pretend the machine has this many registers
")

(defstruct (arguments (:conc-name args-) (:copier nil))
  command file (out nil) (stage "asm") (checks t) (optimise t) (max-regs nil))

(defun parse-arguments (argv)
  (let ((a (make-arguments :command nil :file nil))
        (positional '()))
    (loop while argv
          do (let ((arg (pop argv)))
               (cond
                 ((or (string= arg "-o") (string= arg "--out")) (setf (args-out a) (pop argv)))
                 ((or (string= arg "-s") (string= arg "--stage")) (setf (args-stage a) (pop argv)))
                 ((string= arg "--no-checks") (setf (args-checks a) nil))
                 ((string= arg "--no-opt") (setf (args-optimise a) nil))
                 ((string= arg "--max-regs")
                  (setf (args-max-regs a) (parse-integer (pop argv))))
                 ((and (> (length arg) 1) (char= (char arg 0) #\-))
                  (error "unknown option `~A`" arg))
                 (t (push arg positional)))))
    (setf positional (nreverse positional))
    (setf (args-command a) (first positional))
    (setf (args-file a) (second positional))
    a))

(defun options-of (a)
  (driver:make-options (args-checks a) (args-optimise a) (args-max-regs a)))

(defun read-source (path)
  (with-open-file (stream path :direction :input :external-format :utf-8)
    (let ((text (make-string (file-length stream))))
      (subseq text 0 (read-sequence text stream)))))

(defun stdin-text ()
  (if (interactive-stream-p *standard-input*)
      ""
      (with-output-to-string (out)
        (loop for line = (read-line *standard-input* nil nil)
              while line do (write-line line out)))))

(defun main (&optional (argv (rest sb-ext:*posix-argv*)))
  (let ((a (handler-case (parse-arguments argv)
             (error (c) (format *error-output* "wolv: ~A~%" c) (return-from main 1)))))
    (unless (and (args-command a) (args-file a)
                 (member (args-command a) '("build" "run" "check" "emit") :test #'string=))
      (write-string *usage* *error-output*)
      (return-from main 1))
    (unless (member (args-stage a) driver:+stages+ :test #'string=)
      (format *error-output* "wolv: no such stage as `~A`~%" (args-stage a))
      (return-from main 1))
    (let ((source (handler-case (read-source (args-file a))
                    (error (c) (format *error-output* "wolv: ~A~%" c)
                      (return-from main 1))))
          (opts (options-of a)))
      (handler-case
          (progn
            (cond
              ((string= (args-command a) "check") (driver:to-ir source opts))
              ((string= (args-command a) "emit")
               (write-string (driver:stage source (args-stage a) opts)))
              ((string= (args-command a) "build")
               (driver:build source (or (args-out a) (default-output (args-file a))) opts))
              ((string= (args-command a) "run")
               (let ((done (driver:run source opts (stdin-text))))
                 (write-string (driver:outcome-out done))
                 (write-string (driver:outcome-err done) *error-output*)
                 (finish-output)
                 (return-from main (driver:outcome-status done)))))
            (finish-output)
            0)
        (diag:wolv-error (c)
          (format *error-output* "~A:~A~%" (args-file a) (diag:wolv-error-text c))
          1)
        ((or driver:toolchain-error spill:out-of-registers) (c)
          (format *error-output* "wolv: ~A~%" c)
          1)))))

(defun default-output (file)
  (let ((path (pathname file)))
    (namestring (make-pathname :type nil :defaults path))))

(defun toplevel ()
  (sb-ext:exit :code (main) :abort nil))

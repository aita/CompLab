;;;; A test harness, in about eighty lines.
;;;;
;;;; Common Lisp has no test framework of its own and this tree has no
;;;; dependencies, so the harness is a macro: `deftest` registers a closure,
;;;; `is` counts a check and remembers the form it was written as, and
;;;; `run-all` runs them in the order they were defined.  A failure says which
;;;; expression failed, because the macro kept it.

(defpackage #:wolv.test
  (:use #:cl)
  (:export #:in-suite #:deftest #:is #:is= #:signals #:skip
           #:run-all #:run-suite #:*suite*
           #:tree-file #:read-file #:split-lines))

(in-package #:wolv.test)

(defun tree-file (relative)
  "A file of this tree, found through the system rather than through
`*load-truename*` -- which, once ASDF is compiling into its cache, is not where
the sources are."
  (asdf:system-relative-pathname "wolv" relative))

(defun read-file (path) (uiop:read-file-string path))

(defun split-lines (text)
  (loop with start = 0
        for i = (position #\Newline text :start start)
        collect (subseq text start (or i (length text)))
        while i do (setf start (1+ i))))

(defvar *tests* '() "Every test, in the order it was defined.")
(defvar *suite* "" "The suite the tests being defined belong to.")
(defvar *current* "")
(defvar *checks* 0)
(defvar *failures* '())
(defvar *skipped* '())

(defun register (suite name thunk)
  (setf *tests* (remove (cons suite name) *tests* :key #'first :test #'equal))
  (setf *tests* (nconc *tests* (list (list (cons suite name) thunk)))))

(defmacro in-suite (name)
  "The suite the tests below belong to, until the next `in-suite`."
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (setf *suite* ,name)))

(defmacro deftest (name &body body)
  "One test.  NAME is a string; the body is checks."
  `(register *suite* ,name (lambda () ,@body)))

(defun fail (what)
  (push (format nil "~A: ~A" *current* what) *failures*))

(defmacro is (form &optional note)
  "Check that FORM is true."
  `(progn (incf *checks*)
          (unless ,form
            (fail (format nil "~S is false~@[ (~A)~]" ',form ,note)))))

(defmacro is= (want got &optional note)
  "Check that GOT equals WANT, and say what it was when it does not."
  (let ((w (gensym)) (g (gensym)))
    `(let ((,w ,want) (,g ,got))
       (incf *checks*)
       (unless (equal ,w ,g)
         (fail (format nil "~S~@[ (~A)~]~%      wanted ~S~%      got    ~S"
                       ',got ,note ,w ,g))))))

(defmacro signals (type substring &body body)
  "Check that BODY signals TYPE, and that the message mentions SUBSTRING."
  `(progn
     (incf *checks*)
     (handler-case (progn ,@body
                          (fail (format nil "~S did not signal ~A" ',body ',type)))
       (,type (c)
         (let ((text (princ-to-string c)))
           (unless (search ,substring text)
             (fail (format nil "~S said ~S, wanted ~S" ',body text ,substring))))))))

(defun skip (why)
  (push (format nil "~A: ~A" *current* why) *skipped*))

;; -- running ------------------------------------------------------------------

(defun run-one (key thunk)
  (let ((*current* (format nil "~A/~A" (car key) (cdr key)))
        (before (length *failures*)))
    (handler-case (funcall thunk)
      (error (c) (fail (format nil "signalled ~A: ~A" (type-of c) c))))
    (= before (length *failures*))))

(defun run-suite (&optional suite)
  (let ((*checks* 0) (*failures* '()) (*skipped* '())
        (ran 0) (passed 0))
    (dolist (entry *tests*)
      (destructuring-bind (key thunk) entry
        (when (or (null suite) (equal (car key) suite))
          (incf ran)
          (when (run-one key thunk) (incf passed)))))
    (dolist (line (reverse *skipped*)) (format t "~&  skipped ~A~%" line))
    (dolist (line (reverse *failures*)) (format t "~&FAIL ~A~%" line))
    (format t "~&~D/~D tests, ~D checks~@[, ~D failures~]~%"
            passed ran *checks*
            (when *failures* (length *failures*)))
    (null *failures*)))

(defun run-all ()
  (unless (run-suite)
    (error "the tests failed")))

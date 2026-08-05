;;;; Source positions, and the one condition every pass signals.
;;;;
;;;; A compile error is a condition, not a returned value, so no pass has to
;;;; carry a failure back through the one above it: the lexer signals and the
;;;; command line is where it is caught.  `parse-error` is Common Lisp's own
;;;; name for something else, so this package shadows it -- the name belongs to
;;;; the compiler more than it does to `read`.

(defpackage #:wolv.diag
  (:use #:cl)
  (:shadow #:parse-error)
  (:export #:span #:span-p #:span-line #:span-col #:span-text
           #:wolv-error #:lex-error #:parse-error #:type-check-error
           #:error-span #:error-message #:wolv-error-text))

(in-package #:wolv.diag)

(defstruct (span (:constructor span (line col)) (:copier nil))
  "A position in the source, counted from one."
  (line 1 :type fixnum :read-only t)
  (col 1 :type fixnum :read-only t))

(defun span-text (s)
  (format nil "~D:~D" (span-line s) (span-col s)))

(define-condition wolv-error (error)
  ((span :initarg :span :reader error-span)
   (message :initarg :message :reader error-message))
  (:report (lambda (c stream) (write-string (wolv-error-text c) stream)))
  (:documentation "A user-facing compile error, carrying where it happened."))

(defun wolv-error-text (c)
  (format nil "~A: ~A" (span-text (error-span c)) (error-message c)))

(define-condition lex-error (wolv-error) ())
(define-condition parse-error (wolv-error) ())
(define-condition type-check-error (wolv-error) ())

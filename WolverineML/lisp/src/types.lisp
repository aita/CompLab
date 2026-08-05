;;;; Semantic types, and the symbols that carry them.
;;;;
;;;; Types are monomorphic.  Records are nominal -- two record types with the
;;;; same fields are different types -- and everything else is structural,
;;;; which for this language means arrays compare by their element type.
;;;;
;;;; Comparing two types is a question about both of them at once, so it is
;;;; written as a generic function and answered by methods that specialise on
;;;; both arguments.  `same-p` is five methods and a default that says no;
;;;; `compatible-p` is three more and a default that asks `same-p`.  There is
;;;; no dispatching `case` anywhere, and the rule about `nil` -- that it stands
;;;; in for any record -- is two methods rather than a clause in a conditional.

(defpackage #:wolv.types
  (:use #:cl)
  (:export #:wolv-type #:int-type #:string-type #:bool-type #:unit-type
           #:nil-type #:record-type #:array-type
           #:+int+ #:+string+ #:+bool+ #:+unit+ #:+nil+
           #:elem #:type-name #:fields #:field-index #:field-type
           #:same-p #:compatible-p #:type-text
           #:var-sym #:make-var-sym #:var-sym-p
           #:var-sym-name #:var-sym-ty #:var-sym-mutable #:var-sym-depth
           #:var-sym-escapes #:var-sym-slot #:var-sym-reg
           #:fun-sym #:make-fun-sym #:fun-sym-p
           #:fun-sym-name #:fun-sym-label #:fun-sym-params #:fun-sym-result
           #:fun-sym-depth #:fun-sym-builtin))

(in-package #:wolv.types)

(defclass wolv-type () ())

(defclass int-type (wolv-type) ())
(defclass string-type (wolv-type) ())
(defclass bool-type (wolv-type) ())
(defclass unit-type (wolv-type) ())

(defclass nil-type (wolv-type) ()
  (:documentation "The type of `nil` before it is known which record it stands for."))

(defclass record-type (wolv-type)
  ((type-name :initarg :name :reader type-name)
   (fields :initarg :fields :accessor fields :initform '()))
  (:documentation "Nominal: identity is what makes two of these the same."))

(defclass array-type (wolv-type)
  ((elem :initarg :elem :reader elem)))

;; The four types that have exactly one value apiece, made once.
(defvar +int+ (make-instance 'int-type))
(defvar +string+ (make-instance 'string-type))
(defvar +bool+ (make-instance 'bool-type))
(defvar +unit+ (make-instance 'unit-type))
(defvar +nil+ (make-instance 'nil-type))

;; -- how a type is written ----------------------------------------------------

(defgeneric type-text (ty)
  (:documentation "What an error message calls this type."))

(defmethod type-text ((ty int-type)) "int")
(defmethod type-text ((ty string-type)) "string")
(defmethod type-text ((ty bool-type)) "bool")
(defmethod type-text ((ty unit-type)) "unit")
(defmethod type-text ((ty nil-type)) "nil")
(defmethod type-text ((ty record-type)) (type-name ty))
(defmethod type-text ((ty array-type))
  (format nil "~A array" (type-text (elem ty))))

(defmethod print-object ((ty wolv-type) stream)
  (if *print-escape*
      (print-unreadable-object (ty stream :type t :identity t))
      (write-string (type-text ty) stream)))

;; -- the fields of a record ---------------------------------------------------

(defun field-index (rec name)
  (or (position name (fields rec) :key #'car :test #'string=) -1))

(defun field-type (rec name)
  (let ((found (assoc name (fields rec) :test #'string=)))
    (and found (cdr found))))

;; -- equality -----------------------------------------------------------------

(defgeneric same-p (a b)
  (:documentation "Type equality: nominal for records, structural for arrays."))

(defmethod same-p (a b) (declare (ignore a b)) nil)
(defmethod same-p ((a int-type) (b int-type)) t)
(defmethod same-p ((a string-type) (b string-type)) t)
(defmethod same-p ((a bool-type) (b bool-type)) t)
(defmethod same-p ((a unit-type) (b unit-type)) t)
(defmethod same-p ((a nil-type) (b nil-type)) t)
(defmethod same-p ((a record-type) (b record-type)) (eq a b))
(defmethod same-p ((a array-type) (b array-type)) (same-p (elem a) (elem b)))

(defgeneric compatible-p (a b)
  (:documentation "Equality, but `nil` stands in for any record."))

(defmethod compatible-p (a b) (same-p a b))
(defmethod compatible-p ((a nil-type) (b record-type)) (declare (ignore a b)) t)
(defmethod compatible-p ((a record-type) (b nil-type)) (declare (ignore a b)) t)
(defmethod compatible-p ((a nil-type) (b nil-type)) (declare (ignore a b)) t)

;; -- symbols ------------------------------------------------------------------

(defstruct (var-sym (:copier nil))
  "One binding occurrence of a variable.

DEPTH is the static nesting depth of the function that binds it.  A variable
read from a deeper function escapes, and then it lives in a frame slot instead
of a register."
  (name "" :type string)
  ty
  (mutable nil)
  (depth 0 :type fixnum)
  (escapes nil)
  (slot -1 :type fixnum)
  (reg -1 :type fixnum))

(defstruct (fun-sym (:copier nil))
  "A function.  Functions are not values, so there is no function type."
  (name "" :type string)
  (label "" :type string)
  (params '() :type list)
  result
  (depth 0 :type fixnum)
  (builtin nil))

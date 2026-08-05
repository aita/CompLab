;;;; The syntax tree.
;;;;
;;;; The tree the parser builds is untyped; the checker fills in the `ty` and
;;;; `sym` slots as it goes, and everything after it reads them.
;;;;
;;;; Every node is a class, because every pass over the tree -- checking,
;;;; lowering, printing -- is a generic function with a method per node, and a
;;;; method needs a class to hang on.  `defnode` writes the `defclass` from a
;;;; list of slot names, so what a node declares is what a node is.
;;;;
;;;; The names avoid `if`, `let`, `while` and `array`, which belong to Common
;;;; Lisp and cannot be taken from it.

(defpackage #:wolv.ast
  (:use #:cl)
  (:export #:defwalk
           #:ty-exp #:ty-name #:ty-array #:ty-record #:ty-field
           #:make-ty-field #:ty-field-name #:ty-field-ty #:ty-field-span
           #:expression #:span #:ty
           #:int-lit #:str-lit #:bool-lit #:nil-lit #:unit-lit
           #:var-ref #:call-exp #:record-lit #:index-exp #:field-exp
           #:neg-exp #:bin-exp #:logic-exp #:assign-exp
           #:if-exp #:while-exp #:for-exp #:break-exp #:seq-exp #:let-exp
           #:decl #:type-decl #:val-decl #:fun-decl
           #:type-bind #:make-type-bind #:type-bind-name #:type-bind-ty
           #:type-bind-span
           #:param #:make-param #:param-name #:param-ty #:param-span #:param-sym
           #:fun-bind #:make-fun-bind #:fun-bind-name #:fun-bind-params
           #:fun-bind-result #:fun-bind-body #:fun-bind-span #:fun-bind-sym
           #:field-init #:make-field-init #:field-init-name #:field-init-value
           #:field-init-span
           #:program #:make-program #:program-decls
           #:name #:elem #:value #:sym #:args #:tyname #:fields
           #:arr #:index #:record #:offset #:operand #:op #:lhs #:rhs
           #:target #:test #:then #:els #:body #:lo #:hi #:items #:decls
           #:init #:mutable #:binds #:result #:params))

(in-package #:wolv.ast)

(defmacro defwalk (name (node &rest extra) &body clauses)
  "A pass over the tree: one clause per node, `(CLASS (SLOT...) BODY...)`.

Each clause becomes a method, and the slots it names become variables bound to
what the accessors answer -- so a body says `lhs` where it would otherwise say
`(ast:lhs e)`.  The class and the slots are read in this package however the
caller spelled them, which is what lets a pass write `bin-exp` and not
`ast:bin-exp` twice a line.

Common Lisp has no pattern matching of its own; this is fourteen lines of macro
rather than a dependency, and the clauses read the way the other ports' `match`
does."
  (flet ((here (symbol) (intern (string symbol) '#:wolv.ast)))
    `(progn
       (defgeneric ,name (,node ,@extra))
       ,@(loop for (class slots . body) in clauses
               collect `(defmethod ,name ((,node ,(here class)) ,@extra)
                          (declare (ignorable ,node ,@extra))
                          (let ,(loop for slot in slots
                                      collect `(,slot (,(here slot) ,node)))
                            (declare (ignorable ,@slots))
                            ,@body)))
       ',name)))

(defmacro defnode (name (&rest supers) &rest slots)
  "One node of the tree: a class whose slots are all initargs and accessors.

A slot is either NAME or (NAME DEFAULT)."
  `(defclass ,name ,supers
     ,(loop for slot in slots
            for (slot-name default) = (if (consp slot) slot (list slot nil))
            collect `(,slot-name :initarg ,(intern (string slot-name) :keyword)
                                 :initform ,default
                                 :accessor ,slot-name))))

;; -- types as they are written ------------------------------------------------

(defnode ty-exp () span)
(defnode ty-name (ty-exp) name)
(defnode ty-array (ty-exp) elem)
(defnode ty-record (ty-exp) fields)

(defstruct (ty-field (:constructor make-ty-field (name ty span)) (:copier nil))
  name ty span)

;; -- expressions --------------------------------------------------------------

(defnode expression () span ty)

(defnode int-lit (expression) value)
(defnode str-lit (expression) value)
(defnode bool-lit (expression) value)
(defnode nil-lit (expression))
(defnode unit-lit (expression))
(defnode var-ref (expression) name sym)
(defnode call-exp (expression) name args sym)
(defnode record-lit (expression) tyname fields)
(defnode index-exp (expression) arr index)
(defnode field-exp (expression) record name (offset -1))
(defnode neg-exp (expression) operand)
(defnode bin-exp (expression) op lhs rhs)

(defnode logic-exp (expression) op lhs rhs)
(setf (documentation 'logic-exp 'type)
      "`andalso` and `orelse`, which are control flow, not operators.")

(defnode assign-exp (expression) target value)
(defnode if-exp (expression) test then els)
(defnode while-exp (expression) test body)
(defnode for-exp (expression) name lo hi body sym)
(defnode break-exp (expression))
(defnode seq-exp (expression) items)
(defnode let-exp (expression) decls body)

(defstruct (field-init (:constructor make-field-init (name value span))
                       (:copier nil))
  name value span)

;; -- declarations -------------------------------------------------------------

(defnode decl () span)
(defnode type-decl (decl) binds)
(defnode val-decl (decl) name ty init mutable sym)
(defnode fun-decl (decl) binds)

(defstruct (type-bind (:constructor make-type-bind (name ty span)) (:copier nil))
  name ty span)

(defstruct (param (:constructor make-param (name ty span)) (:copier nil))
  name ty span (sym nil))

(defstruct (fun-bind (:constructor make-fun-bind (name params result body span))
                     (:copier nil))
  name params result body span (sym nil))

(defstruct (program (:constructor make-program (decls)) (:copier nil))
  decls)

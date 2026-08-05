;;;; The type checker, which also decides which variables escape.
;;;;
;;;; Types are monomorphic and there is nothing to infer but the type of a
;;;; `val`.  A `fun` without a result type is a procedure and returns `unit`,
;;;; which is what makes recursion checkable without inference: every
;;;; function's signature is known before any body is.
;;;;
;;;; The pass has a second job.  A variable read from inside a function nested
;;;; more deeply than the one that binds it cannot live in a register, because
;;;; the inner function reaches it through a static link at run time.  Every
;;;; lookup that crosses a function boundary marks the variable as escaping,
;;;; and the lowering pass gives those a frame slot instead.
;;;;
;;;; There is no `case` over node kinds here.  `check-exp` is a generic
;;;; function and each form of expression answers it with a method of its own,
;;;; so the checker's rule for `while` sits next to nothing but the rule for
;;;; `while`.  What that costs is the exhaustiveness a `case` would give: a
;;;; node nobody wrote a method for is a run-time error, which is what the last
;;;; method here is.

(defpackage #:wolv.typecheck
  (:use #:cl)
  (:local-nicknames (#:ast #:wolv.ast)
                    (#:diag #:wolv.diag)
                    (#:ty #:wolv.types))
  (:export #:check #:checker))

(in-package #:wolv.typecheck)

(defparameter *builtins*
  ;; name, argument types, result, and the symbol the runtime exports.
  `(("print"       (,ty:+string+)                        ,ty:+unit+   "wol_print")
    ("println"     (,ty:+string+)                        ,ty:+unit+   "wol_println")
    ("printInt"    (,ty:+int+)                           ,ty:+unit+   "wol_print_int")
    ("flush"       ()                                    ,ty:+unit+   "wol_flush")
    ("getChar"     ()                                    ,ty:+string+ "wol_getchar")
    ("ord"         (,ty:+string+)                        ,ty:+int+    "wol_ord")
    ("chr"         (,ty:+int+)                           ,ty:+string+ "wol_chr")
    ("size"        (,ty:+string+)                        ,ty:+int+    "wol_size")
    ("substring"   (,ty:+string+ ,ty:+int+ ,ty:+int+)    ,ty:+string+ "wol_substring")
    ("concat"      (,ty:+string+ ,ty:+string+)           ,ty:+string+ "wol_concat")
    ("intToString" (,ty:+int+)                           ,ty:+string+ "wol_int_to_string")
    ("stringToInt" (,ty:+string+)                        ,ty:+int+    "wol_string_to_int")
    ("exit"        (,ty:+int+)                           ,ty:+unit+   "wol_exit")))

(defparameter *arithmetic* '("+" "-" "*" "/" "mod"))
(defparameter *orderings* '("<" "<=" ">" ">="))
(defparameter *equalities* '("=" "<>"))

(defstruct (scope (:constructor make-scope ()) (:copier nil))
  (types (make-hash-table :test #'equal))
  (vals (make-hash-table :test #'equal)))

(defclass checker ()
  ((scopes :initform '() :accessor scopes)
   (depth :initform 0 :accessor depth)
   (loops :initform 0 :accessor loops)
   (labels* :initform (make-hash-table :test #'equal) :reader labels*)))

(defmethod initialize-instance :after ((ck checker) &key)
  (setf (scopes ck) (list (prelude))))

(defun prelude ()
  (let ((s (make-scope)))
    (loop for (name value) in `(("int" ,ty:+int+) ("string" ,ty:+string+)
                                ("bool" ,ty:+bool+) ("unit" ,ty:+unit+))
          do (setf (gethash name (scope-types s)) value))
    (loop for (name params result symbol) in *builtins*
          do (setf (gethash name (scope-vals s))
                   (ty:make-fun-sym
                    :name name :label symbol
                    :params (loop for p in params for i from 0
                                  collect (ty:make-var-sym :name (format nil "a~D" i)
                                                           :ty p :depth 0))
                    :result result :depth 0 :builtin symbol)))
    (dolist (name '("array" "length" "not"))
      (setf (gethash name (scope-vals s))
            (ty:make-fun-sym :name name :label name :result ty:+unit+ :builtin name)))
    s))

;; -- scopes -------------------------------------------------------------------

(defun push-scope (ck) (push (make-scope) (scopes ck)))
(defun pop-scope (ck) (pop (scopes ck)))

(defun bind-val (ck name sym)
  (setf (gethash name (scope-vals (first (scopes ck)))) sym))

(defun bind-type (ck name type)
  (setf (gethash name (scope-types (first (scopes ck)))) type))

(defun lookup-val (ck name span)
  (dolist (s (scopes ck)
             (error 'diag:type-check-error :span span
                                           :message (format nil "`~A` is not bound" name)))
    (let ((found (gethash name (scope-vals s))))
      (when found (return found)))))

(defun lookup-type (ck name span)
  (dolist (s (scopes ck)
             (error 'diag:type-check-error :span span
                                           :message (format nil "`~A` is not a type" name)))
    (let ((found (gethash name (scope-types s))))
      (when found (return found)))))

(defun unique-label (ck name)
  (let ((n (gethash name (labels* ck) 0)))
    (setf (gethash name (labels* ck)) (1+ n))
    (if (zerop n) (format nil "wol_~A" name) (format nil "wol_~A.~D" name n))))

;; -- what a mismatch says -----------------------------------------------------

(defun unify (want got span where)
  (unless (ty:compatible-p want got)
    (error 'diag:type-check-error
           :span span
           :message (format nil "expected `~A`, found `~A` ~A"
                            (ty:type-text want) (ty:type-text got) where))))

;; -- programs and declarations ------------------------------------------------

(defun check (prog)
  "Type PROG in place: every node comes back with its TY slot filled in."
  (let ((ck (make-instance 'checker)))
    (push-scope ck)
    (check-decls ck (ast:program-decls prog))
    (pop-scope ck)
    prog))

(defun check-decls (ck decls)
  (dolist (d decls) (check-decl d ck)))

(defgeneric check-decl (decl ck))

(defmethod check-decl ((d ast:decl) ck)
  (declare (ignore ck))
  (error 'diag:type-check-error :span (ast:span d) :message "unknown declaration"))

(defmethod check-decl ((d ast:type-decl) ck)
  ;; The names come first so that a record may mention itself, or another in
  ;; the same group; the fields are resolved once every name is bound.
  (let ((records '()))
    (dolist (bind (ast:binds d))
      (let ((written (ast:type-bind-ty bind)))
        (when (typep written 'ast:ty-record)
          (let ((rec (make-instance 'ty:record-type :name (ast:type-bind-name bind))))
            (bind-type ck (ast:type-bind-name bind) rec)
            (push (cons rec written) records)))))
    (dolist (bind (ast:binds d))
      (unless (typep (ast:type-bind-ty bind) 'ast:ty-record)
        (bind-type ck (ast:type-bind-name bind) (resolve ck (ast:type-bind-ty bind)))))
    (dolist (pair (nreverse records))
      (destructuring-bind (rec . written) pair
        (let ((seen '()))
          (dolist (f (ast:fields written))
            (when (member (ast:ty-field-name f) seen :test #'string=)
              (error 'diag:type-check-error
                     :span (ast:ty-field-span f)
                     :message (format nil "duplicate field `~A`" (ast:ty-field-name f))))
            (push (ast:ty-field-name f) seen)
            (setf (ty:fields rec)
                  (append (ty:fields rec)
                          (list (cons (ast:ty-field-name f)
                                      (resolve ck (ast:ty-field-ty f))))))))))))

(defgeneric resolve-ty (written ck)
  (:documentation "A type as it was written, as the type it means."))

(defun resolve (ck written) (resolve-ty written ck))

(defmethod resolve-ty ((w ast:ty-exp) ck)
  (declare (ignore ck))
  (error 'diag:type-check-error :span (ast:span w) :message "unknown type"))

(defmethod resolve-ty ((w ast:ty-name) ck)
  (lookup-type ck (ast:name w) (ast:span w)))

(defmethod resolve-ty ((w ast:ty-array) ck)
  (make-instance 'ty:array-type :elem (resolve ck (ast:elem w))))

(defmethod resolve-ty ((w ast:ty-record) ck)
  (declare (ignore ck))
  (error 'diag:type-check-error :span (ast:span w)
                                :message "a record type has to be given a name by `type`"))

(defmethod check-decl ((d ast:val-decl) ck)
  (let* ((got (exp-type ck (ast:init d)))
         (want (when (ast:ty d) (resolve ck (ast:ty d)))))
    (when want
      (unify want got (ast:span (ast:init d)) "in this binding")
      (setf got want))
    (cond
      ((null (ast:name d))
       (unify ty:+unit+ got (ast:span (ast:init d)) "in `val () =`"))
      ((typep got 'ty:nil-type)
       (error 'diag:type-check-error
              :span (ast:span d)
              :message (format nil "`~A` needs a type annotation to hold `nil`"
                               (ast:name d))))
      (t
       (let ((sym (ty:make-var-sym :name (ast:name d) :ty got
                                   :mutable (ast:mutable d) :depth (depth ck))))
         (setf (ast:sym d) sym)
         (bind-val ck (ast:name d) sym))))))

(defmethod check-decl ((d ast:fun-decl) ck)
  ;; Every signature is read before any body, which is what lets a group recurse.
  (dolist (bind (ast:binds d))
    (let ((params '()) (seen '()))
      (dolist (p (ast:fun-bind-params bind))
        (when (member (ast:param-name p) seen :test #'string=)
          (error 'diag:type-check-error
                 :span (ast:param-span p)
                 :message (format nil "duplicate parameter `~A`" (ast:param-name p))))
        (push (ast:param-name p) seen)
        (let ((sym (ty:make-var-sym :name (ast:param-name p)
                                    :ty (resolve ck (ast:param-ty p))
                                    :depth (1+ (depth ck)))))
          (setf (ast:param-sym p) sym)
          (push sym params)))
      (let* ((result (if (ast:fun-bind-result bind)
                         (resolve ck (ast:fun-bind-result bind))
                         ty:+unit+))
             (fsym (ty:make-fun-sym :name (ast:fun-bind-name bind)
                                    :label (unique-label ck (ast:fun-bind-name bind))
                                    :params (nreverse params)
                                    :result result
                                    :depth (1+ (depth ck)))))
        (setf (ast:fun-bind-sym bind) fsym)
        (bind-val ck (ast:fun-bind-name bind) fsym))))
  (dolist (bind (ast:binds d))
    (let ((signature (ast:fun-bind-sym bind))
          (outer-loops (loops ck)))
      (incf (depth ck))
      (setf (loops ck) 0)
      (push-scope ck)
      (dolist (p (ast:fun-bind-params bind))
        (bind-val ck (ast:param-name p) (ast:param-sym p)))
      (let ((got (exp-type ck (ast:fun-bind-body bind))))
        (unify (ty:fun-sym-result signature) got
               (ast:span (ast:fun-bind-body bind))
               (format nil "in the body of `~A`" (ast:fun-bind-name bind))))
      (pop-scope ck)
      (setf (loops ck) outer-loops)
      (decf (depth ck)))))

;; -- expressions --------------------------------------------------------------

(defun exp-type (ck e)
  "Check E, remember its type on the node, and answer with it."
  (setf (ast:ty e) (check-exp e ck)))

(defgeneric check-exp (e ck)
  (:documentation "The type of E, and the escapes and offsets found on the way."))

(defmethod check-exp ((e ast:expression) ck)
  (declare (ignore ck))
  (error 'diag:type-check-error :span (ast:span e) :message "unknown expression"))

(defmethod check-exp ((e ast:int-lit) ck) (declare (ignore ck)) ty:+int+)
(defmethod check-exp ((e ast:str-lit) ck) (declare (ignore ck)) ty:+string+)
(defmethod check-exp ((e ast:bool-lit) ck) (declare (ignore ck)) ty:+bool+)
(defmethod check-exp ((e ast:nil-lit) ck) (declare (ignore ck)) ty:+nil+)
(defmethod check-exp ((e ast:unit-lit) ck) (declare (ignore ck)) ty:+unit+)

(defmethod check-exp ((e ast:var-ref) ck)
  (let ((sym (lookup-val ck (ast:name e) (ast:span e))))
    (when (ty:fun-sym-p sym)
      (error 'diag:type-check-error
             :span (ast:span e)
             :message (format nil "`~A` is a function, and functions are not values"
                              (ast:name e))))
    ;; Read from deeper than it was bound: it cannot live in a register.
    (when (< (ty:var-sym-depth sym) (depth ck))
      (setf (ty:var-sym-escapes sym) t))
    (setf (ast:sym e) sym)
    (ty:var-sym-ty sym)))

(defun arity (e want)
  (let ((given (length (ast:args e))))
    (unless (= given want)
      (error 'diag:type-check-error
             :span (ast:span e)
             :message (format nil "`~A` takes ~D argument~:[s~;~], given ~D"
                              (ast:name e) want (= want 1) given)))))

(defmethod check-exp ((e ast:call-exp) ck)
  (let ((sym (lookup-val ck (ast:name e) (ast:span e))))
    (when (ty:var-sym-p sym)
      (error 'diag:type-check-error
             :span (ast:span e)
             :message (format nil "`~A` is a variable, not a function" (ast:name e))))
    (setf (ast:sym e) sym)
    (let ((builtin (ty:fun-sym-builtin sym)))
      (cond
        ((equal builtin "array") (check-array-call e ck))
        ((equal builtin "length") (check-length-call e ck))
        ((equal builtin "not")
         (arity e 1)
         (unify ty:+bool+ (exp-type ck (first (ast:args e))) (ast:span e)
                "in a call to `not`")
         ty:+bool+)
        (t
         (arity e (length (ty:fun-sym-params sym)))
         (loop for arg in (ast:args e)
               for param in (ty:fun-sym-params sym)
               do (unify (ty:var-sym-ty param) (exp-type ck arg) (ast:span arg)
                         (format nil "in a call to `~A`" (ast:name e))))
         (ty:fun-sym-result sym))))))

(defun check-array-call (e ck)
  (arity e 2)
  (unify ty:+int+ (exp-type ck (first (ast:args e)))
         (ast:span (first (ast:args e))) "as an array length")
  (let ((elem (exp-type ck (second (ast:args e)))))
    (when (typep elem 'ty:nil-type)
      (error 'diag:type-check-error
             :span (ast:span (second (ast:args e)))
             :message "`array` cannot tell which record `nil` stands for"))
    (make-instance 'ty:array-type :elem elem)))

(defun check-length-call (e ck)
  (arity e 1)
  (let ((arg (exp-type ck (first (ast:args e)))))
    (unless (typep arg 'ty:array-type)
      (error 'diag:type-check-error
             :span (ast:span (first (ast:args e)))
             :message (format nil "`length` wants an array, found `~A`"
                              (ty:type-text arg))))
    ty:+int+))

(defmethod check-exp ((e ast:record-lit) ck)
  (let ((rec (lookup-type ck (ast:tyname e) (ast:span e))))
    (unless (typep rec 'ty:record-type)
      (error 'diag:type-check-error
             :span (ast:span e)
             :message (format nil "`~A` is not a record type" (ast:tyname e))))
    (let ((given (make-hash-table :test #'equal)))
      (dolist (f (ast:fields e))
        (when (gethash (ast:field-init-name f) given)
          (error 'diag:type-check-error
                 :span (ast:field-init-span f)
                 :message (format nil "field `~A` is given twice" (ast:field-init-name f))))
        (when (minusp (ty:field-index rec (ast:field-init-name f)))
          (error 'diag:type-check-error
                 :span (ast:field-init-span f)
                 :message (format nil "`~A` has no field `~A`"
                                  (ty:type-name rec) (ast:field-init-name f))))
        (setf (gethash (ast:field-init-name f) given) f))
      ;; The fields are put into declaration order, which is the order the
      ;; lowering stores them in.
      (setf (ast:fields e)
            (loop for (name . field-ty) in (ty:fields rec)
                  for init = (gethash name given)
                  do (unless init
                       (error 'diag:type-check-error
                              :span (ast:span e)
                              :message (format nil "field `~A` is missing" name)))
                     (unify field-ty (exp-type ck (ast:field-init-value init))
                            (ast:field-init-span init)
                            (format nil "in field `~A`" name))
                  collect init))
      rec)))

(defmethod check-exp ((e ast:index-exp) ck)
  (let ((arr (exp-type ck (ast:arr e))))
    (unless (typep arr 'ty:array-type)
      (error 'diag:type-check-error
             :span (ast:span e)
             :message (format nil "`~A` is not an array" (ty:type-text arr))))
    (unify ty:+int+ (exp-type ck (ast:index e)) (ast:span (ast:index e))
           "as an array index")
    (ty:elem arr)))

(defmethod check-exp ((e ast:field-exp) ck)
  (let ((rec (exp-type ck (ast:record e))))
    (unless (typep rec 'ty:record-type)
      (error 'diag:type-check-error
             :span (ast:span e)
             :message (format nil "`~A` is not a record" (ty:type-text rec))))
    (let ((field-ty (ty:field-type rec (ast:name e))))
      (unless field-ty
        (error 'diag:type-check-error
               :span (ast:span e)
               :message (format nil "`~A` has no field `~A`"
                                (ty:type-name rec) (ast:name e))))
      (setf (ast:offset e) (ty:field-index rec (ast:name e)))
      field-ty)))

(defmethod check-exp ((e ast:neg-exp) ck)
  (unify ty:+int+ (exp-type ck (ast:operand e)) (ast:span e) "in a negation")
  ty:+int+)

(defmethod check-exp ((e ast:bin-exp) ck)
  (let ((lhs (exp-type ck (ast:lhs e)))
        (rhs (exp-type ck (ast:rhs e)))
        (op (ast:op e)))
    (cond
      ((member op *arithmetic* :test #'string=)
       (unify ty:+int+ lhs (ast:span (ast:lhs e)) (format nil "on the left of `~A`" op))
       (unify ty:+int+ rhs (ast:span (ast:rhs e)) (format nil "on the right of `~A`" op))
       ty:+int+)
      ((string= op "^")
       (unify ty:+string+ lhs (ast:span (ast:lhs e)) "on the left of `^`")
       (unify ty:+string+ rhs (ast:span (ast:rhs e)) "on the right of `^`")
       ty:+string+)
      ((member op *orderings* :test #'string=)
       (unless (typep lhs '(or ty:int-type ty:string-type))
         (error 'diag:type-check-error
                :span (ast:span e)
                :message (format nil "`~A` compares int or string, not `~A`"
                                 op (ty:type-text lhs))))
       (unify lhs rhs (ast:span (ast:rhs e)) (format nil "on the right of `~A`" op))
       ty:+bool+)
      ((member op *equalities* :test #'string=)
       (when (or (typep lhs 'ty:unit-type) (typep rhs 'ty:unit-type))
         (error 'diag:type-check-error
                :span (ast:span e)
                :message (format nil "`~A` cannot compare `unit`" op)))
       (unless (ty:compatible-p lhs rhs)
         (error 'diag:type-check-error
                :span (ast:span e)
                :message (format nil "`~A` compares `~A` with `~A`"
                                 op (ty:type-text lhs) (ty:type-text rhs))))
       ty:+bool+)
      (t (error 'diag:type-check-error
                :span (ast:span e)
                :message (format nil "unknown operator `~A`" op))))))

(defmethod check-exp ((e ast:logic-exp) ck)
  (unify ty:+bool+ (exp-type ck (ast:lhs e)) (ast:span (ast:lhs e))
         (format nil "on the left of `~A`" (ast:op e)))
  (unify ty:+bool+ (exp-type ck (ast:rhs e)) (ast:span (ast:rhs e))
         (format nil "on the right of `~A`" (ast:op e)))
  ty:+bool+)

(defmethod check-exp ((e ast:assign-exp) ck)
  (let ((target (exp-type ck (ast:target e))))
    (let ((place (ast:target e)))
      (when (and (typep place 'ast:var-ref)
                 (ast:sym place)
                 (not (ty:var-sym-mutable (ast:sym place))))
        (error 'diag:type-check-error
               :span (ast:span e)
               :message (format nil "`~A` is a `val`, so it cannot be assigned"
                                (ty:var-sym-name (ast:sym place))))))
    (unify target (exp-type ck (ast:value e)) (ast:span (ast:value e))
           "in an assignment")
    ty:+unit+))

(defmethod check-exp ((e ast:if-exp) ck)
  (unify ty:+bool+ (exp-type ck (ast:test e)) (ast:span (ast:test e))
         "as an `if` condition")
  (let ((then (exp-type ck (ast:then e))))
    (if (null (ast:els e))
        (progn
          (unify ty:+unit+ then (ast:span (ast:then e)) "in an `if` with no `else`")
          ty:+unit+)
        (let ((els (exp-type ck (ast:els e))))
          (unless (ty:compatible-p then els)
            (error 'diag:type-check-error
                   :span (ast:span e)
                   :message (format nil "the branches differ: `~A` and `~A`"
                                    (ty:type-text then) (ty:type-text els))))
          (if (typep then 'ty:nil-type) els then)))))

(defmethod check-exp ((e ast:while-exp) ck)
  (unify ty:+bool+ (exp-type ck (ast:test e)) (ast:span (ast:test e))
         "as a `while` condition")
  (incf (loops ck))
  (unify ty:+unit+ (exp-type ck (ast:body e)) (ast:span (ast:body e))
         "in a `while` body")
  (decf (loops ck))
  ty:+unit+)

(defmethod check-exp ((e ast:for-exp) ck)
  (unify ty:+int+ (exp-type ck (ast:lo e)) (ast:span (ast:lo e)) "as a `for` bound")
  (unify ty:+int+ (exp-type ck (ast:hi e)) (ast:span (ast:hi e)) "as a `for` bound")
  (let ((sym (ty:make-var-sym :name (ast:name e) :ty ty:+int+ :depth (depth ck))))
    (setf (ast:sym e) sym)
    (push-scope ck)
    (bind-val ck (ast:name e) sym)
    (incf (loops ck))
    (unify ty:+unit+ (exp-type ck (ast:body e)) (ast:span (ast:body e))
           "in a `for` body")
    (decf (loops ck))
    (pop-scope ck)
    ty:+unit+))

(defmethod check-exp ((e ast:break-exp) ck)
  (when (zerop (loops ck))
    (error 'diag:type-check-error :span (ast:span e)
                                  :message "`break` is outside any loop"))
  ty:+unit+)

(defmethod check-exp ((e ast:seq-exp) ck)
  (let ((result ty:+unit+))
    (dolist (item (ast:items e) result)
      (setf result (exp-type ck item)))))

(defmethod check-exp ((e ast:let-exp) ck)
  (push-scope ck)
  (check-decls ck (ast:decls e))
  (let ((result (exp-type ck (ast:body e))))
    (pop-scope ck)
    result))

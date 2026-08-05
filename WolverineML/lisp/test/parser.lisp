(defpackage #:wolv.test.parser
  (:use #:cl #:wolv.test)
  (:local-nicknames (#:ast #:wolv.ast) (#:diag #:wolv.diag) (#:parser #:wolv.parser)))

(in-package #:wolv.test.parser)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (setf *suite* "parser"))

;; A parenthesised sketch of the tree, so precedence is easy to assert.  It is
;; a generic function like every other walk over this tree.
(defgeneric shape (e))

(defun shapes (es) (format nil "~{~A~^ ~}" (mapcar #'shape es)))

(defmethod shape ((e ast:int-lit)) (format nil "~D" (ast:value e)))
(defmethod shape ((e ast:str-lit)) (format nil "\"~A\"" (ast:value e)))
(defmethod shape ((e ast:bool-lit)) (if (ast:value e) "true" "false"))
(defmethod shape ((e ast:nil-lit)) "nil")
(defmethod shape ((e ast:unit-lit)) "()")
(defmethod shape ((e ast:var-ref)) (ast:name e))
(defmethod shape ((e ast:break-exp)) "break")
(defmethod shape ((e ast:neg-exp)) (format nil "(~~ ~A)" (shape (ast:operand e))))
(defmethod shape ((e ast:bin-exp))
  (format nil "(~A ~A ~A)" (ast:op e) (shape (ast:lhs e)) (shape (ast:rhs e))))
(defmethod shape ((e ast:logic-exp))
  (format nil "(~A ~A ~A)" (ast:op e) (shape (ast:lhs e)) (shape (ast:rhs e))))
(defmethod shape ((e ast:assign-exp))
  (format nil "(:= ~A ~A)" (shape (ast:target e)) (shape (ast:value e))))
(defmethod shape ((e ast:if-exp))
  (format nil "(if ~A ~A~@[ ~A~])" (shape (ast:test e)) (shape (ast:then e))
          (when (ast:els e) (shape (ast:els e)))))
(defmethod shape ((e ast:while-exp))
  (format nil "(while ~A ~A)" (shape (ast:test e)) (shape (ast:body e))))
(defmethod shape ((e ast:for-exp))
  (format nil "(for ~A ~A ~A ~A)" (ast:name e) (shape (ast:lo e)) (shape (ast:hi e))
          (shape (ast:body e))))
(defmethod shape ((e ast:seq-exp)) (format nil "(seq ~A)" (shapes (ast:items e))))
(defmethod shape ((e ast:call-exp))
  (format nil "(~A ~A)" (ast:name e) (shapes (ast:args e))))
(defmethod shape ((e ast:index-exp))
  (format nil "(index ~A ~A)" (shape (ast:arr e)) (shape (ast:index e))))
(defmethod shape ((e ast:field-exp))
  (format nil "(field ~A ~A)" (shape (ast:record e)) (ast:name e)))
(defmethod shape ((e ast:record-lit))
  (format nil "(record ~A ~{~A~^ ~})" (ast:tyname e)
          (loop for f in (ast:fields e)
                collect (format nil "~A=~A" (ast:field-init-name f)
                                (shape (ast:field-init-value f))))))
(defmethod shape ((e ast:let-exp))
  (format nil "(let ~D ~A)" (length (ast:decls e)) (shape (ast:body e))))

(defun sketch (source) (shape (parser:parse-exp-string source)))

(deftest "arithmetic precedence"
  (is= "(+ 1 (* 2 3))" (sketch "1 + 2 * 3"))
  (is= "(+ (* 1 2) 3)" (sketch "1 * 2 + 3"))
  (is= "(- (- 1 2) 3)" (sketch "1 - 2 - 3"))
  (is= "(= (+ 1 2) 3)" (sketch "1 + 2 = 3")))

(deftest "logic binds looser than comparison"
  (is= "(andalso (< a b) (> c d))" (sketch "a < b andalso c > d"))
  (is= "(orelse a (andalso b c))" (sketch "a orelse b andalso c")))

(deftest "assignment is right-associative and loosest"
  (is= "(:= x (+ y 1))" (sketch "x := y + 1")))

(deftest "a branch swallows what follows it"
  (is= "(if c (:= x 1) (:= x 2))" (sketch "if c then x := 1 else x := 2"))
  (is= "(if c a (+ b 1))" (sketch "if c then a else b + 1")))

(deftest "postfix chains"
  (is= "(index (field (index a i) f) j)" (sketch "a[i].f[j]"))
  (is= "(field (f 1 2) g)" (sketch "f(1, 2).g")))

(deftest "sequences and unit"
  (is= "()" (sketch "()"))
  (is= "(seq a b c)" (sketch "(a; b; c)"))
  (is= "a" (sketch "(a)")))

(deftest "negation is a tilde"
  (is= "(+ (~ x) 1)" (sketch "~x + 1"))
  (signals diag:parse-error "negation is written" (parser:parse-exp-string "-x")))

(deftest "a record literal is not a call"
  (is= "(record point x=1 y=2)" (sketch "point { x = 1, y = 2 }"))
  (is= "(point 1 2)" (sketch "point (1, 2)")))

(deftest "let with declarations"
  (is= "(let 2 (+ x y))" (sketch "let val x = 1 var y = 2 in x + y end")))

(deftest "a program is declarations"
  (let ((decls (ast:program-decls
                (parser:parse (format nil "type t = int~Aval x = 1~Afun f (a : int) : int = a~A"
                                      #\Newline #\Newline #\Newline)))))
    (is (typep (first decls) 'ast:type-decl))
    (is (typep (second decls) 'ast:val-decl))
    (is (typep (third decls) 'ast:fun-decl))))

(deftest "mutual recursion is one declaration"
  (let ((decls (ast:program-decls
                (parser:parse (format nil "fun f () : int = g ()~Aand g () : int = 1~A"
                                      #\Newline #\Newline)))))
    (is= 1 (length decls))
    (is= '("f" "g") (mapcar #'ast:fun-bind-name (ast:binds (first decls))))))

(deftest "only a place can be assigned"
  (signals diag:parse-error "not assignable" (parser:parse-exp-string "1 + 2 := 3")))

(deftest "errors name what was expected"
  (signals diag:parse-error "expected `then`" (parser:parse-exp-string "if a do b")))

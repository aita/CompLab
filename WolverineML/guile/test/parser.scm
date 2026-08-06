;;; The parser, and the precedence table it is.

(use-modules (oop goops)
             (srfi srfi-1)
             (srfi srfi-64)
             (ice-9 format)
             (harness)
             (wolv diag)
             (wolv ast)
             (wolv parser))

;; A parenthesised sketch of the tree, so precedence is easy to assert.  One
;; method per node, as everywhere else in this tree.
(define-generic shape)

(define (all es) (string-join (map shape es) " "))

(define-method (shape (e <e-int>)) (number->string (e-int-value e)))
(define-method (shape (e <e-str>)) (format #f "\"~a\"" (e-str-value e)))
(define-method (shape (e <e-bool>)) (if (e-bool-value e) "true" "false"))
(define-method (shape (e <e-nil>)) "nil")
(define-method (shape (e <e-unit>)) "()")
(define-method (shape (e <e-var>)) (e-var-name e))
(define-method (shape (e <e-neg>)) (format #f "(~~ ~a)" (shape (e-neg-operand e))))
(define-method (shape (e <e-binary>))
  (format #f "(~a ~a ~a)" (binary-op e) (shape (binary-lhs e)) (shape (binary-rhs e))))
(define-method (shape (e <e-assign>))
  (format #f "(:= ~a ~a)" (shape (e-assign-target e)) (shape (e-assign-value e))))
(define-method (shape (e <e-if>))
  (format #f "(if ~a ~a~a)" (shape (e-if-test e)) (shape (e-if-then e))
          (if (e-if-else e) (format #f " ~a" (shape (e-if-else e))) "")))
(define-method (shape (e <e-while>))
  (format #f "(while ~a ~a)" (shape (e-while-test e)) (shape (e-while-body e))))
(define-method (shape (e <e-for>))
  (format #f "(for ~a ~a ~a ~a)" (e-for-binder e) (shape (e-for-lo e))
          (shape (e-for-hi e)) (shape (e-for-body e))))
(define-method (shape (e <e-break>)) "break")
(define-method (shape (e <e-seq>)) (format #f "(seq ~a)" (all (e-seq-items e))))
(define-method (shape (e <e-call>))
  (format #f "(~a ~a)" (e-call-callee e) (all (e-call-args e))))
(define-method (shape (e <e-index>))
  (format #f "(index ~a ~a)" (shape (e-index-array e)) (shape (e-index-index e))))
(define-method (shape (e <e-field>))
  (format #f "(field ~a ~a)" (shape (e-field-record e)) (e-field-select e)))
(define-method (shape (e <e-record>))
  (format #f "(record ~a ~a)" (e-record-tyname e)
          (string-join (map (lambda (f)
                              (format #f "~a=~a" (field-init-name f)
                                      (shape (field-init-value f))))
                            (e-record-inits e))
                       " ")))
(define-method (shape (e <e-let>))
  (format #f "(let ~a ~a)" (length (e-let-decls e)) (shape (e-let-body e))))

(define (sketch source) (shape (parse-one-exp source)))

(with-suite
 "parser"
 (lambda ()

   (test-equal "1 + 2 * 3" "(+ 1 (* 2 3))" (sketch "1 + 2 * 3"))
   (test-equal "1 * 2 + 3" "(+ (* 1 2) 3)" (sketch "1 * 2 + 3"))
   (test-equal "1 - 2 - 3" "(- (- 1 2) 3)" (sketch "1 - 2 - 3"))
   (test-equal "1 + 2 = 3" "(= (+ 1 2) 3)" (sketch "1 + 2 = 3"))

   (test-equal "logic binds looser than comparison"
     "(andalso (< a b) (> c d))" (sketch "a < b andalso c > d"))
   (test-equal "andalso binds tighter than orelse"
     "(orelse a (andalso b c))" (sketch "a orelse b andalso c"))

   (test-equal "assignment is right-associative and loosest"
     "(:= x (+ y 1))" (sketch "x := y + 1"))

   (test-equal "a branch swallows what follows it"
     "(if c (:= x 1) (:= x 2))" (sketch "if c then x := 1 else x := 2"))
   (test-equal "and only what follows it"
     "(if c a (+ b 1))" (sketch "if c then a else b + 1"))

   (test-equal "postfix chains"
     "(index (field (index a i) f) j)" (sketch "a[i].f[j]"))
   (test-equal "a call is an atom too"
     "(field (f 1 2) g)" (sketch "f(1, 2).g"))

   (test-equal "unit" "()" (sketch "()"))
   (test-equal "a sequence" "(seq a b c)" (sketch "(a; b; c)"))
   (test-equal "one thing in brackets is that thing" "a" (sketch "(a)"))

   (test-equal "negation is a tilde" "(+ (~ x) 1)" (sketch "~x + 1"))
   (test-assert "and a minus is not"
     (raises? 'parse "negation is written" (lambda () (parse-one-exp "-x"))))

   (test-equal "a record literal is not a call"
     "(record point x=1 y=2)" (sketch "point { x = 1, y = 2 }"))
   (test-equal "and a call is not a record literal"
     "(point 1 2)" (sketch "point (1, 2)"))

   (test-equal "let with declarations"
     "(let 2 (+ x y))" (sketch "let val x = 1 var y = 2 in x + y end"))

   (test-assert "a program is declarations"
     (let ((prog (parse "type t = int\nval x = 1\nfun f (a : int) : int = a\n")))
       (and (is-a? (first prog) <d-type>)
            (is-a? (second prog) <d-val>)
            (is-a? (third prog) <d-fun>))))

   (test-equal "mutual recursion is one declaration"
     '("f" "g")
     (map fun-bind-label
          (d-fun-binds (first (parse "fun f () : int = g ()\nand g () : int = 1\n")))))

   (test-assert "only a place can be assigned"
     (raises? 'parse "not assignable" (lambda () (parse-one-exp "1 + 2 := 3"))))

   (test-assert "errors name what was expected"
     (raises? 'parse "expected `then`" (lambda () (parse-one-exp "if a do b"))))))

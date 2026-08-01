#lang racket/base

(require rackunit
         racket/list
         racket/string
         "../src/diag.rkt"
         "../src/parser.rkt"
         (prefix-in ast: "../src/ast.rkt"))

(provide parser-tests)

(define (parse-error? message)
  (λ (e) (and (exn:wolv? e) (eq? (exn:wolv-kind e) 'parse)
              (regexp-match? (regexp-quote message) (exn-message e)))))

;; A parenthesised sketch of the tree, so precedence is easy to assert.
(define (shape e)
  (define n (ast:exp-node e))
  (define (all es) (string-join (map shape es) " "))
  (cond
    [(ast:e:int? n) (number->string (ast:e:int-value n))]
    [(ast:e:str? n) (format "\"~a\"" (ast:e:str-value n))]
    [(ast:e:bool? n) (if (ast:e:bool-value n) "true" "false")]
    [(ast:e:nil? n) "nil"]
    [(ast:e:unit? n) "()"]
    [(ast:e:var? n) (ast:e:var-name n)]
    [(ast:e:neg? n) (format "(~~ ~a)" (shape (ast:e:neg-operand n)))]
    [(ast:e:bin? n) (format "(~a ~a ~a)" (ast:e:bin-op n)
                            (shape (ast:e:bin-lhs n)) (shape (ast:e:bin-rhs n)))]
    [(ast:e:logic? n) (format "(~a ~a ~a)" (ast:e:logic-op n)
                              (shape (ast:e:logic-lhs n)) (shape (ast:e:logic-rhs n)))]
    [(ast:e:assign? n) (format "(:= ~a ~a)" (shape (ast:e:assign-target n))
                               (shape (ast:e:assign-value n)))]
    [(ast:e:if? n)
     (format "(if ~a ~a~a)" (shape (ast:e:if-cond n)) (shape (ast:e:if-then n))
             (if (ast:e:if-els n) (format " ~a" (shape (ast:e:if-els n))) ""))]
    [(ast:e:while? n) (format "(while ~a ~a)" (shape (ast:e:while-cond n))
                              (shape (ast:e:while-body n)))]
    [(ast:e:for? n) (format "(for ~a ~a ~a ~a)" (ast:e:for-binder n)
                            (shape (ast:e:for-lo n)) (shape (ast:e:for-hi n))
                            (shape (ast:e:for-body n)))]
    [(ast:e:break? n) "break"]
    [(ast:e:seq? n) (format "(seq ~a)" (all (ast:e:seq-items n)))]
    [(ast:e:call? n) (format "(~a ~a)" (ast:e:call-callee n) (all (ast:e:call-args n)))]
    [(ast:e:index? n) (format "(index ~a ~a)" (shape (ast:e:index-array n))
                              (shape (ast:e:index-index n)))]
    [(ast:e:field? n) (format "(field ~a ~a)" (shape (ast:e:field-record n))
                              (ast:e:field-select n))]
    [(ast:e:record? n)
     (format "(record ~a ~a)" (ast:e:record-tyname n)
             (string-join (for/list ([f (in-list (ast:e:record-inits n))])
                            (format "~a=~a" (ast:field-init-name f)
                                    (shape (ast:field-init-value f))))
                          " "))]
    [else (format "(let ~a ~a)" (length (ast:e:let-decls n))
                  (shape (ast:e:let-body n)))]))

(define (sketch source) (shape (parse-one-exp source)))

(define parser-tests
  (test-suite
   "parser"

   (test-case "arithmetic precedence"
     (check-equal? (sketch "1 + 2 * 3") "(+ 1 (* 2 3))")
     (check-equal? (sketch "1 * 2 + 3") "(+ (* 1 2) 3)")
     (check-equal? (sketch "1 - 2 - 3") "(- (- 1 2) 3)")
     (check-equal? (sketch "1 + 2 = 3") "(= (+ 1 2) 3)"))

   (test-case "logic binds looser than comparison"
     (check-equal? (sketch "a < b andalso c > d") "(andalso (< a b) (> c d))")
     (check-equal? (sketch "a orelse b andalso c") "(orelse a (andalso b c))"))

   (test-case "assignment is right-associative and loosest"
     (check-equal? (sketch "x := y + 1") "(:= x (+ y 1))"))

   (test-case "a branch swallows what follows it"
     (check-equal? (sketch "if c then x := 1 else x := 2") "(if c (:= x 1) (:= x 2))")
     (check-equal? (sketch "if c then a else b + 1") "(if c a (+ b 1))"))

   (test-case "postfix chains"
     (check-equal? (sketch "a[i].f[j]") "(index (field (index a i) f) j)")
     (check-equal? (sketch "f(1, 2).g") "(field (f 1 2) g)"))

   (test-case "sequences and unit"
     (check-equal? (sketch "()") "()")
     (check-equal? (sketch "(a; b; c)") "(seq a b c)")
     (check-equal? (sketch "(a)") "a"))

   (test-case "negation is a tilde"
     (check-equal? (sketch "~x + 1") "(+ (~ x) 1)")
     (check-exn (parse-error? "negation is written") (λ () (parse-one-exp "-x"))))

   (test-case "a record literal is not a call"
     (check-equal? (sketch "point { x = 1, y = 2 }") "(record point x=1 y=2)")
     (check-equal? (sketch "point (1, 2)") "(point 1 2)"))

   (test-case "let with declarations"
     (check-equal? (sketch "let val x = 1 var y = 2 in x + y end") "(let 2 (+ x y))"))

   (test-case "a program is declarations"
     (define prog (parse "type t = int\nval x = 1\nfun f (a : int) : int = a\n"))
     (check-true (ast:d:type? (first prog)))
     (check-true (ast:d:val? (second prog)))
     (check-true (ast:d:fun? (third prog))))

   (test-case "mutual recursion is one declaration"
     (define prog (parse "fun f () : int = g ()\nand g () : int = 1\n"))
     (check-equal? (for/list ([b (in-list (ast:d:fun-binds (first prog)))])
                     (ast:fun-bind-label b))
                   '("f" "g")))

   (test-case "only a place can be assigned"
     (check-exn (parse-error? "not assignable") (λ () (parse-one-exp "1 + 2 := 3"))))

   (test-case "errors name what was expected"
     (check-exn (parse-error? "expected `then`") (λ () (parse-one-exp "if a do b"))))))

(module+ test (require rackunit/text-ui) (void (run-tests parser-tests)))

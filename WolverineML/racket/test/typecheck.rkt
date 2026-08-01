#lang racket/base

(require rackunit
         racket/list
         "../src/diag.rkt"
         "../src/parser.rkt"
         (prefix-in types: "../src/typecheck.rkt")
         "../src/types.rkt"
         (prefix-in ast: "../src/ast.rkt"))

(provide typecheck-tests)

(define (accepts source)
  (define prog (parse source))
  (types:check prog)
  prog)

(define (type-error? message)
  (λ (e) (and (exn:wolv? e) (eq? (exn:wolv-kind e) 'type)
              (regexp-match? (regexp-quote message) (exn-message e)))))

(define-syntax-rule (rejects source message)
  (check-exn (type-error? message) (λ () (accepts source))))

(define typecheck-tests
  (test-suite
   "typecheck"

   (test-case "arithmetic is on ints"
     (accepts "val x = 1 + 2")
     (rejects "val x = 1 + \"a\"" "expected `int`, found `string`")
     (rejects "val x = true + 1" "expected `int`, found `bool`"))

   (test-case "concatenation is on strings"
     (accepts "val s = \"a\" ^ \"b\"")
     (rejects "val s = \"a\" ^ 1" "expected `string`, found `int`"))

   (test-case "comparison gives bool"
     (accepts "val b = 1 < 2 andalso 3 >= 4")
     (rejects "val b = \"a\" < 1" "expected `string`, found `int`")
     (rejects "val b = true < false" "compares int or string"))

   (test-case "equality needs one type"
     (accepts "val b = 1 = 2")
     (accepts "val b = \"a\" <> \"b\"")
     (rejects "val b = 1 = true" "compares `int` with `bool`"))

   (test-case "conditions are bool"
     (accepts "val x = if true then 1 else 2")
     (rejects "val x = if 1 then 1 else 2" "expected `bool`, found `int`")
     (rejects "val x = if true then 1 else \"a\"" "the branches differ")
     (rejects "val () = if true then 1" "in an `if` with no `else`"))

   (test-case "a val cannot be assigned"
     (accepts "var x = 1 val () = x := 2")
     (rejects "val x = 1 val () = x := 2" "is a `val`"))

   (test-case "functions check their arguments"
     (accepts "fun f (a : int) : int = a\nval x = f (1)")
     (rejects "fun f (a : int) : int = a\nval x = f (1, 2)" "takes 1 argument")
     (rejects "fun f (a : int) : int = a\nval x = f (\"s\")" "expected `int`"))

   (test-case "a fun without a result is a procedure"
     (accepts "fun f () = print (\"x\")\nval () = f ()")
     (rejects "fun f () = 1" "expected `unit`, found `int`"))

   (test-case "functions are not values"
     (rejects "fun f () : int = 1\nval x = f" "functions are not values"))

   (test-case "records are nominal"
     (accepts "type p = { x : int }\nval a = p { x = 1 }\nval b = a.x")
     (rejects (string-append "type p = { x : int } and q = { x : int }\n"
                             "fun f (r : p) : int = r.x\nval x = f (q { x = 1 })")
              "expected `p`, found `q`")
     (rejects "type p = { x : int }\nval a = p { y = 1 }" "has no field `y`")
     (rejects "type p = { x : int, y : int }\nval a = p { x = 1 }" "field `y` is missing"))

   (test-case "nil belongs to every record type"
     (accepts "type p = { x : int }\nval a : p = nil\nval b = a = nil")
     (rejects "val a = nil" "needs a type annotation")
     (rejects "type p = { x : int }\nval a : p = nil\nval b = a = 1" "compares"))

   (test-case "arrays know their element"
     (accepts "val a = array (3, 0)\nval x = a[0] + 1")
     (accepts "type ints = int array\nval a : ints = array (3, 0)")
     (rejects "val a = array (3, 0)\nval x = a[0] ^ \"s\"" "expected `string`")
     (rejects "val a = array (3, 0)\nval x = a[true]" "as an array index")
     (rejects "val x = length (1)" "`length` wants an array"))

   (test-case "break is inside a loop"
     (accepts "val () = while true do break")
     (accepts "val () = for i = 0 to 3 do break")
     (rejects "val () = break" "outside any loop")
     (rejects "val () = while true do let fun f () = break in f () end"
              "outside any loop"))

   (test-case "escape analysis marks what a nested function reads"
     (define prog
       (accepts (string-append "fun outer () : int =\n"
                               "  let var kept = 1\n"
                               "      val plain = 2\n"
                               "      fun inner () : int = kept\n"
                               "  in inner () + plain end\n")))
     (define body (ast:fun-bind-body (first (ast:d:fun-binds (first prog)))))
     (define decls (ast:e:let-decls (ast:exp-node body)))
     (check-true (var-sym-escapes? (ast:d:val-sym (first decls))))
     (check-false (var-sym-escapes? (ast:d:val-sym (second decls)))))

   (test-case "a parameter escapes too"
     (define prog
       (accepts (string-append "fun outer (n : int) : int =\n"
                               "  let fun inner () : int = n in inner () end\n")))
     (define param (first (ast:fun-bind-params (first (ast:d:fun-binds (first prog))))))
     (check-true (var-sym-escapes? (ast:param-sym param))))

   (test-case "recursive types"
     (accepts (string-append
               "type list = { head : int, tail : list }\n"
               "fun sum (l : list) : int = if l = nil then 0 else l.head + sum (l.tail)\n"))
     (accepts "type a = b array and b = { next : a }"))

   (test-case "unbound names"
     (rejects "val x = y" "`y` is not bound")
     (rejects "val x : t = 1" "`t` is not a type")
     (rejects "val x = f ()" "`f` is not bound"))))

(module+ test (require rackunit/text-ui) (void (run-tests typecheck-tests)))

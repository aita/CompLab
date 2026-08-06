;;; The checker, and the escape analysis it does on the side.

(use-modules (oop goops)
             (srfi srfi-1)
             (srfi srfi-64)
             (harness)
             (wolv diag)
             (wolv types)
             (wolv ast)
             (wolv parser)
             (wolv typecheck))

(define (accepts source)
  (let ((prog (parse source)))
    (check prog)
    prog))

(define (rejects? source message)
  (raises? 'type message (lambda () (accepts source))))

(with-suite
 "typecheck"
 (lambda ()

   (test-assert "arithmetic is on ints" (accepts "val x = 1 + 2"))
   (test-assert "and not on strings"
     (rejects? "val x = 1 + \"a\"" "expected `int`, found `string`"))
   (test-assert "nor on bools"
     (rejects? "val x = true + 1" "expected `int`, found `bool`"))

   (test-assert "concatenation is on strings" (accepts "val s = \"a\" ^ \"b\""))
   (test-assert "and only on strings"
     (rejects? "val s = \"a\" ^ 1" "expected `string`, found `int`"))

   (test-assert "comparison gives bool" (accepts "val b = 1 < 2 andalso 3 >= 4"))
   (test-assert "both sides agree"
     (rejects? "val b = \"a\" < 1" "expected `string`, found `int`"))
   (test-assert "and bools do not order"
     (rejects? "val b = true < false" "compares int or string"))

   (test-assert "equality needs one type" (accepts "val b = 1 = 2"))
   (test-assert "strings compare" (accepts "val b = \"a\" <> \"b\""))
   (test-assert "int and bool do not"
     (rejects? "val b = 1 = true" "compares `int` with `bool`"))

   (test-assert "conditions are bool" (accepts "val x = if true then 1 else 2"))
   (test-assert "and not ints"
     (rejects? "val x = if 1 then 1 else 2" "expected `bool`, found `int`"))
   (test-assert "the branches agree"
     (rejects? "val x = if true then 1 else \"a\"" "the branches differ"))
   (test-assert "with no else the branch is unit"
     (rejects? "val () = if true then 1" "in an `if` with no `else`"))

   (test-assert "a var can be assigned" (accepts "var x = 1 val () = x := 2"))
   (test-assert "a val cannot" (rejects? "val x = 1 val () = x := 2" "is a `val`"))

   (test-assert "functions check their arguments"
     (accepts "fun f (a : int) : int = a\nval x = f (1)"))
   (test-assert "and how many there are"
     (rejects? "fun f (a : int) : int = a\nval x = f (1, 2)" "takes 1 argument"))
   (test-assert "and what they are"
     (rejects? "fun f (a : int) : int = a\nval x = f (\"s\")" "expected `int`"))

   (test-assert "a fun without a result is a procedure"
     (accepts "fun f () = print (\"x\")\nval () = f ()"))
   (test-assert "so its body is unit" (rejects? "fun f () = 1" "expected `unit`, found `int`"))

   (test-assert "functions are not values"
     (rejects? "fun f () : int = 1\nval x = f" "functions are not values"))

   (test-assert "records are nominal"
     (accepts "type p = { x : int }\nval a = p { x = 1 }\nval b = a.x"))
   (test-assert "so two of the same shape differ"
     (rejects? (lines "type p = { x : int } and q = { x : int }"
                      "fun f (r : p) : int = r.x"
                      "val x = f (q { x = 1 })")
               "expected `p`, found `q`"))
   (test-assert "a field has to exist"
     (rejects? "type p = { x : int }\nval a = p { y = 1 }" "has no field `y`"))
   (test-assert "and all of them have to be given"
     (rejects? "type p = { x : int, y : int }\nval a = p { x = 1 }" "field `y` is missing"))

   (test-assert "nil belongs to every record type"
     (accepts "type p = { x : int }\nval a : p = nil\nval b = a = nil"))
   (test-assert "but has to be told which"
     (rejects? "val a = nil" "needs a type annotation"))
   (test-assert "and is not an int"
     (rejects? "type p = { x : int }\nval a : p = nil\nval b = a = 1" "compares"))

   (test-assert "arrays know their element"
     (accepts "val a = array (3, 0)\nval x = a[0] + 1"))
   (test-assert "an array type can be named"
     (accepts "type ints = int array\nval a : ints = array (3, 0)"))
   (test-assert "the element is what it was made of"
     (rejects? "val a = array (3, 0)\nval x = a[0] ^ \"s\"" "expected `string`"))
   (test-assert "an index is an int"
     (rejects? "val a = array (3, 0)\nval x = a[true]" "as an array index"))
   (test-assert "length wants an array"
     (rejects? "val x = length (1)" "`length` wants an array"))

   (test-assert "break is inside a while" (accepts "val () = while true do break"))
   (test-assert "or inside a for" (accepts "val () = for i = 0 to 3 do break"))
   (test-assert "and nowhere else" (rejects? "val () = break" "outside any loop"))
   (test-assert "a nested function is nowhere else"
     (rejects? "val () = while true do let fun f () = break in f () end"
               "outside any loop"))

   (test-assert "escape analysis marks what a nested function reads"
     (let* ((prog (accepts (lines "fun outer () : int ="
                                  "  let var kept = 1"
                                  "      val plain = 2"
                                  "      fun inner () : int = kept"
                                  "  in inner () + plain end")))
            (body (fun-bind-body (first (d-fun-binds (first prog)))))
            (decls (e-let-decls body)))
       (and (var-sym-escapes? (d-val-sym (first decls)))
            (not (var-sym-escapes? (d-val-sym (second decls)))))))

   (test-assert "a parameter escapes too"
     (let* ((prog (accepts (lines "fun outer (n : int) : int ="
                                  "  let fun inner () : int = n in inner () end")))
            (p (first (fun-bind-params (first (d-fun-binds (first prog)))))))
       (var-sym-escapes? (param-sym p))))

   (test-assert "recursive types"
     (accepts (lines "type list = { head : int, tail : list }"
                     "fun sum (l : list) : int = if l = nil then 0 else l.head + sum (l.tail)")))
   (test-assert "and mutually recursive ones"
     (accepts "type a = b array and b = { next : a }"))

   (test-assert "an unbound name" (rejects? "val x = y" "`y` is not bound"))
   (test-assert "an unbound type" (rejects? "val x : t = 1" "`t` is not a type"))
   (test-assert "an unbound function" (rejects? "val x = f ()" "`f` is not bound"))))

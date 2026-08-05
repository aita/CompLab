(defpackage #:wolv.test.typecheck
  (:use #:cl #:wolv.test)
  (:local-nicknames (#:ast #:wolv.ast) (#:diag #:wolv.diag)
                    (#:parser #:wolv.parser) (#:ty #:wolv.types)
                    (#:types #:wolv.typecheck)))

(in-package #:wolv.test.typecheck)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (setf *suite* "typecheck"))

(defun accepts (source) (types:check (parser:parse source)))

(defmacro rejects (source message)
  `(signals diag:type-check-error ,message (accepts ,source)))

(defun lines (&rest parts) (format nil "~{~A~^~%~}~%" parts))

(deftest "arithmetic is on ints"
  (accepts "val x = 1 + 2")
  (rejects "val x = 1 + \"a\"" "expected `int`, found `string`")
  (rejects "val x = true + 1" "expected `int`, found `bool`"))

(deftest "concatenation is on strings"
  (accepts "val s = \"a\" ^ \"b\"")
  (rejects "val s = \"a\" ^ 1" "expected `string`, found `int`"))

(deftest "comparison gives bool"
  (accepts "val b = 1 < 2 andalso 3 >= 4")
  (rejects "val b = \"a\" < 1" "expected `string`, found `int`")
  (rejects "val b = true < false" "compares int or string"))

(deftest "equality needs one type"
  (accepts "val b = 1 = 2")
  (accepts "val b = \"a\" <> \"b\"")
  (rejects "val b = 1 = true" "compares `int` with `bool`"))

(deftest "conditions are bool"
  (accepts "val x = if true then 1 else 2")
  (rejects "val x = if 1 then 1 else 2" "expected `bool`, found `int`")
  (rejects "val x = if true then 1 else \"a\"" "the branches differ")
  (rejects "val () = if true then 1" "in an `if` with no `else`"))

(deftest "a val cannot be assigned"
  (accepts (lines "var x = 1" "val () = x := 2"))
  (rejects (lines "val x = 1" "val () = x := 2") "is a `val`"))

(deftest "functions check their arguments"
  (accepts (lines "fun f (a : int) : int = a" "val x = f (1)"))
  (rejects (lines "fun f (a : int) : int = a" "val x = f (1, 2)") "takes 1 argument")
  (rejects (lines "fun f (a : int) : int = a" "val x = f (\"s\")") "expected `int`"))

(deftest "a fun without a result is a procedure"
  (accepts (lines "fun f () = print (\"x\")" "val () = f ()"))
  (rejects "fun f () = 1" "expected `unit`, found `int`"))

(deftest "functions are not values"
  (rejects (lines "fun f () : int = 1" "val x = f") "functions are not values"))

(deftest "records are nominal"
  (accepts (lines "type p = { x : int }" "val a = p { x = 1 }" "val b = a.x"))
  (rejects (lines "type p = { x : int } and q = { x : int }"
                  "fun f (r : p) : int = r.x"
                  "val x = f (q { x = 1 })")
           "expected `p`, found `q`")
  (rejects (lines "type p = { x : int }" "val a = p { y = 1 }") "has no field `y`")
  (rejects (lines "type p = { x : int, y : int }" "val a = p { x = 1 }")
           "field `y` is missing"))

(deftest "nil belongs to every record type"
  (accepts (lines "type p = { x : int }" "val a : p = nil" "val b = a = nil"))
  (rejects "val a = nil" "needs a type annotation")
  (rejects (lines "type p = { x : int }" "val a : p = nil" "val b = a = 1") "compares"))

(deftest "arrays know their element"
  (accepts (lines "val a = array (3, 0)" "val x = a[0] + 1"))
  (accepts (lines "type ints = int array" "val a : ints = array (3, 0)"))
  (rejects (lines "val a = array (3, 0)" "val x = a[0] ^ \"s\"") "expected `string`")
  (rejects (lines "val a = array (3, 0)" "val x = a[true]") "as an array index")
  (rejects "val x = length (1)" "`length` wants an array"))

(deftest "break is inside a loop"
  (accepts "val () = while true do break")
  (accepts "val () = for i = 0 to 3 do break")
  (rejects "val () = break" "outside any loop")
  (rejects "val () = while true do let fun f () = break in f () end" "outside any loop"))

(deftest "escape analysis marks what a nested function reads"
  (let* ((prog (accepts (lines "fun outer () : int ="
                               "  let var kept = 1"
                               "      val plain = 2"
                               "      fun inner () : int = kept"
                               "  in inner () + plain end")))
         (body (ast:fun-bind-body (first (ast:binds (first (ast:program-decls prog))))))
         (decls (ast:decls body)))
    (is (ty:var-sym-escapes (ast:sym (first decls))))
    (is (not (ty:var-sym-escapes (ast:sym (second decls)))))))

(deftest "a parameter escapes too"
  (let* ((prog (accepts (lines "fun outer (n : int) : int ="
                               "  let fun inner () : int = n in inner () end")))
         (param (first (ast:fun-bind-params
                        (first (ast:binds (first (ast:program-decls prog))))))))
    (is (ty:var-sym-escapes (ast:param-sym param)))))

(deftest "recursive types"
  (accepts (lines "type list = { head : int, tail : list }"
                  "fun sum (l : list) : int = if l = nil then 0 else l.head + sum (l.tail)"))
  (accepts "type a = b array and b = { next : a }"))

(deftest "unbound names"
  (rejects "val x = y" "`y` is not bound")
  (rejects "val x : t = 1" "`t` is not a type")
  (rejects "val x = f ()" "`f` is not bound"))

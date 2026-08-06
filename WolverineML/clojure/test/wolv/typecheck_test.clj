(ns wolv.typecheck-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [wolv.lexer-test :refer [raises?]]
            [wolv.parser :as parser]
            [wolv.typecheck :as typecheck]))

(defn lines [& parts] (str (str/join "\n" parts) "\n"))

(defn accepts [source] (typecheck/check (parser/parse source)))

(defn rejects? [source message]
  (raises? :type message #(accepts source)))

(deftest arithmetic-is-on-ints
  (is (accepts "val x = 1 + 2"))
  (is (rejects? "val x = 1 + \"a\"" "expected `int`, found `string`"))
  (is (rejects? "val x = true + 1" "expected `int`, found `bool`")))

(deftest concatenation-is-on-strings
  (is (accepts "val s = \"a\" ^ \"b\""))
  (is (rejects? "val s = \"a\" ^ 1" "expected `string`, found `int`")))

(deftest comparison-gives-bool
  (is (accepts "val b = 1 < 2 andalso 3 >= 4"))
  (is (rejects? "val b = \"a\" < 1" "expected `string`, found `int`"))
  (is (rejects? "val b = true < false" "compares int or string")))

(deftest equality-needs-one-type
  (is (accepts "val b = 1 = 2"))
  (is (accepts "val b = \"a\" <> \"b\""))
  (is (rejects? "val b = 1 = true" "compares `int` with `bool`")))

(deftest conditions-are-bool
  (is (accepts "val x = if true then 1 else 2"))
  (is (rejects? "val x = if 1 then 1 else 2" "expected `bool`, found `int`"))
  (is (rejects? "val x = if true then 1 else \"a\"" "the branches differ"))
  (is (rejects? "val () = if true then 1" "in an `if` with no `else`")))

(deftest a-val-cannot-be-assigned
  (is (accepts "var x = 1 val () = x := 2"))
  (is (rejects? "val x = 1 val () = x := 2" "is a `val`")))

(deftest functions-check-their-arguments
  (is (accepts "fun f (a : int) : int = a\nval x = f (1)"))
  (is (rejects? "fun f (a : int) : int = a\nval x = f (1, 2)" "takes 1 argument"))
  (is (rejects? "fun f (a : int) : int = a\nval x = f (\"s\")" "expected `int`")))

(deftest a-fun-without-a-result-is-a-procedure
  (is (accepts "fun f () = print (\"x\")\nval () = f ()"))
  (is (rejects? "fun f () = 1" "expected `unit`, found `int`")))

(deftest functions-are-not-values
  (is (rejects? "fun f () : int = 1\nval x = f" "functions are not values")))

(deftest records-are-nominal
  (is (accepts "type p = { x : int }\nval a = p { x = 1 }\nval b = a.x"))
  (is (rejects? (lines "type p = { x : int } and q = { x : int }"
                       "fun f (r : p) : int = r.x"
                       "val x = f (q { x = 1 })")
                "expected `p`, found `q`"))
  (is (rejects? "type p = { x : int }\nval a = p { y = 1 }" "has no field `y`"))
  (is (rejects? "type p = { x : int, y : int }\nval a = p { x = 1 }" "field `y` is missing")))

(deftest nil-belongs-to-every-record-type
  (is (accepts "type p = { x : int }\nval a : p = nil\nval b = a = nil"))
  (is (rejects? "val a = nil" "needs a type annotation"))
  (is (rejects? "type p = { x : int }\nval a : p = nil\nval b = a = 1" "compares")))

(deftest arrays-know-their-element
  (is (accepts "val a = array (3, 0)\nval x = a[0] + 1"))
  (is (accepts "type ints = int array\nval a : ints = array (3, 0)"))
  (is (rejects? "val a = array (3, 0)\nval x = a[0] ^ \"s\"" "expected `string`"))
  (is (rejects? "val a = array (3, 0)\nval x = a[true]" "as an array index"))
  (is (rejects? "val x = length (1)" "`length` wants an array")))

(deftest break-is-inside-a-loop
  (is (accepts "val () = while true do break"))
  (is (accepts "val () = for i = 0 to 3 do break"))
  (is (rejects? "val () = break" "outside any loop"))
  (is (rejects? "val () = while true do let fun f () = break in f () end"
                "outside any loop")))

(deftest escape-analysis-marks-what-a-nested-function-reads
  (let [{:keys [program escapes]}
        (accepts (lines "fun outer () : int ="
                        "  let var kept = 1"
                        "      val plain = 2"
                        "      fun inner () : int = kept"
                        "  in inner () + plain end"))
        decls (:decls (:body (first (:binds (first program)))))]
    (is (contains? escapes (:id (:sym (first decls)))))
    (is (not (contains? escapes (:id (:sym (second decls))))))))

(deftest a-parameter-escapes-too
  (let [{:keys [program escapes]}
        (accepts (lines "fun outer (n : int) : int ="
                        "  let fun inner () : int = n in inner () end"))
        p (first (:params (first (:binds (first program)))))]
    (is (contains? escapes (:id (:sym p))))))

(deftest recursive-types
  (is (accepts (lines "type list = { head : int, tail : list }"
                      "fun sum (l : list) : int = if l = nil then 0 else l.head + sum (l.tail)")))
  (is (accepts "type a = b array and b = { next : a }")))

(deftest unbound-names
  (is (rejects? "val x = y" "`y` is not bound"))
  (is (rejects? "val x : t = 1" "`t` is not a type"))
  (is (rejects? "val x = f ()" "`f` is not bound")))

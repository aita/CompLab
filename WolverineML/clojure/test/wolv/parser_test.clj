(ns wolv.parser-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [wolv.lexer-test :refer [raises?]]
            [wolv.parser :as parser]))

(defmulti shape
  "A parenthesised sketch of the tree, so precedence is easy to assert."
  :node)

(defn- all [es] (str/join " " (map shape es)))

(defmethod shape :int [e] (str (:value e)))
(defmethod shape :str [e] (str "\"" (:value e) "\""))
(defmethod shape :bool [e] (if (:value e) "true" "false"))
(defmethod shape :nil [_] "nil")
(defmethod shape :unit [_] "()")
(defmethod shape :var [e] (:name e))
(defmethod shape :neg [e] (str "(~ " (shape (:operand e)) ")"))
(defmethod shape :bin [e] (str "(" (:oper e) " " (shape (:lhs e)) " " (shape (:rhs e)) ")"))
(defmethod shape :logic [e] (str "(" (:oper e) " " (shape (:lhs e)) " " (shape (:rhs e)) ")"))
(defmethod shape :assign [e]
  (str "(:= " (shape (:target e)) " " (shape (:value e)) ")"))
(defmethod shape :if [e]
  (str "(if " (shape (:test e)) " " (shape (:then e))
       (if (:else e) (str " " (shape (:else e))) "") ")"))
(defmethod shape :while [e] (str "(while " (shape (:test e)) " " (shape (:body e)) ")"))
(defmethod shape :for [e]
  (str "(for " (:binder e) " " (shape (:lo e)) " " (shape (:hi e))
       " " (shape (:body e)) ")"))
(defmethod shape :break [_] "break")
(defmethod shape :seq [e] (str "(seq " (all (:items e)) ")"))
(defmethod shape :call [e] (str "(" (:callee e) " " (all (:args e)) ")"))
(defmethod shape :index [e]
  (str "(index " (shape (:array e)) " " (shape (:index e)) ")"))
(defmethod shape :field [e] (str "(field " (shape (:record e)) " " (:select e) ")"))
(defmethod shape :record [e]
  (str "(record " (:tyname e) " "
       (str/join " " (map (fn [f] (str (:name f) "=" (shape (:value f)))) (:inits e)))
       ")"))
(defmethod shape :let [e] (str "(let " (count (:decls e)) " " (shape (:body e)) ")"))

(defn sketch [source] (shape (parser/parse-one-exp source)))

(deftest arithmetic-precedence
  (is (= "(+ 1 (* 2 3))" (sketch "1 + 2 * 3")))
  (is (= "(+ (* 1 2) 3)" (sketch "1 * 2 + 3")))
  (is (= "(- (- 1 2) 3)" (sketch "1 - 2 - 3")))
  (is (= "(= (+ 1 2) 3)" (sketch "1 + 2 = 3"))))

(deftest logic-binds-looser-than-comparison
  (is (= "(andalso (< a b) (> c d))" (sketch "a < b andalso c > d")))
  (is (= "(orelse a (andalso b c))" (sketch "a orelse b andalso c"))))

(deftest assignment-is-right-associative-and-loosest
  (is (= "(:= x (+ y 1))" (sketch "x := y + 1"))))

(deftest a-branch-swallows-what-follows-it
  (is (= "(if c (:= x 1) (:= x 2))" (sketch "if c then x := 1 else x := 2")))
  (is (= "(if c a (+ b 1))" (sketch "if c then a else b + 1"))))

(deftest postfix-chains
  (is (= "(index (field (index a i) f) j)" (sketch "a[i].f[j]")))
  (is (= "(field (f 1 2) g)" (sketch "f(1, 2).g"))))

(deftest sequences-and-unit
  (is (= "()" (sketch "()")))
  (is (= "(seq a b c)" (sketch "(a; b; c)")))
  (is (= "a" (sketch "(a)"))))

(deftest negation-is-a-tilde
  (is (= "(+ (~ x) 1)" (sketch "~x + 1")))
  (is (raises? :parse "negation is written" #(parser/parse-one-exp "-x"))))

(deftest a-record-literal-is-not-a-call
  (is (= "(record point x=1 y=2)" (sketch "point { x = 1, y = 2 }")))
  (is (= "(point 1 2)" (sketch "point (1, 2)"))))

(deftest let-with-declarations
  (is (= "(let 2 (+ x y))" (sketch "let val x = 1 var y = 2 in x + y end"))))

(deftest a-program-is-declarations
  (let [prog (parser/parse "type t = int\nval x = 1\nfun f (a : int) : int = a\n")]
    (is (= [:type :val :fun] (mapv :decl prog)))))

(deftest mutual-recursion-is-one-declaration
  (is (= ["f" "g"]
         (mapv :label (:binds (first (parser/parse "fun f () : int = g ()\nand g () : int = 1\n")))))))

(deftest only-a-place-can-be-assigned
  (is (raises? :parse "not assignable" #(parser/parse-one-exp "1 + 2 := 3"))))

(deftest errors-name-what-was-expected
  (is (raises? :parse "expected `then`" #(parser/parse-one-exp "if a do b"))))

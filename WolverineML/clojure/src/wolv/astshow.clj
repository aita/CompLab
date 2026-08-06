(ns wolv.astshow
  "An indented dump of the typed syntax tree, for `wolv emit -s ast`.

  A node answers with the lines it is, so the walk is `mapcat` and there is no
  buffer to write into."
  (:require [clojure.string :as str]
            [wolv.types :as ty]))

(defn- two-digit-hex [n]
  (let [s (Integer/toHexString n)]
    (if (< (count s) 2) (str "0" s) s)))

(defn quoted
  "A string literal, written the way the Python tree writes it, so that a dump
  taken from either is the same dump.  Every character of one is a byte, and a
  byte that stands for nothing printable is shown as `\\xNN`.

  The other ports ask a Unicode database which bytes those are.  Over the range
  a literal can hold — U+0000 to U+00FF — the answer is four fixed ranges: the
  C0 and C1 controls, no-break space, and the soft hyphen."
  [text]
  (let [q (if (and (str/includes? text "'") (not (str/includes? text "\""))) \" \')]
    (str q
         (apply str
                (map (fn [c]
                       (let [n (int c)]
                         (cond
                           (or (= c q) (= c \\)) (str \\ c)
                           (= n 10) "\\n"
                           (= n 13) "\\r"
                           (= n 9) "\\t"
                           (or (<= n 0x1F) (<= 0x7F n 0xA0) (= n 0xAD))
                           (str "\\x" (two-digit-hex n))
                           :else (str c))))
                     text))
         q)))

(defn- indent [depth text] (str (apply str (repeat (* 2 depth) " ")) text))

(defn- escapes-mark [escapes sym]
  (if (and sym (ty/var-sym? sym) (contains? escapes (:id sym))) " (escapes)" ""))

(defn- shown-type [e] (if (:ty e) (str " : " (ty/show-ty (:ty e))) ""))

(declare ^:private show-exp show-decl)

(defn- kids [depth escapes es]
  (mapcat #(show-exp % (inc depth) escapes) es))

(defmulti ^:private show-node (fn [e _depth _escapes] (:op e)))

(defn- show-exp [e depth escapes] (show-node e depth escapes))

(defmethod show-node :int [e d _] [(indent d (str "int " (:value e)))])
(defmethod show-node :str [e d _] [(indent d (str "string " (quoted (:value e))))])
(defmethod show-node :bool [e d _] [(indent d (str "bool " (if (:value e) "true" "false")))])
(defmethod show-node :nil [e d _] [(indent d "nil")])
(defmethod show-node :unit [e d _] [(indent d "()")])
(defmethod show-node :var [e d _] [(indent d (str "var " (:name e) (shown-type e)))])

(defmethod show-node :call [e d esc]
  (cons (indent d (str "call " (:callee e) (shown-type e)))
        (kids d esc (:args e))))

(defmethod show-node :record [e d esc]
  (cons (indent d (str "record " (:tyname e) (shown-type e)))
        (mapcat (fn [f]
                  (cons (indent (inc d) (str (:name f) " ="))
                        (show-exp (:value f) (+ d 2) esc)))
                (:inits e))))

(defmethod show-node :index [e d esc]
  (cons (indent d (str "index" (shown-type e)))
        (kids d esc [(:array e) (:index e)])))

(defmethod show-node :field [e d esc]
  (cons (indent d (str "field ." (:select e) (shown-type e)))
        (kids d esc [(:record e)])))

(defmethod show-node :neg [e d esc]
  (cons (indent d "neg") (kids d esc [(:operand e)])))

(defn- binary [e d esc]
  (cons (indent d (str (:oper e) (shown-type e)))
        (kids d esc [(:lhs e) (:rhs e)])))

(defmethod show-node :bin [e d esc] (binary e d esc))
(defmethod show-node :logic [e d esc] (binary e d esc))

(defmethod show-node :assign [e d esc]
  (cons (indent d ":=") (kids d esc [(:target e) (:value e)])))

(defmethod show-node :if [e d esc]
  (concat [(indent d (str "if" (shown-type e)))]
          (kids d esc [(:test e) (:then e)])
          (when (:else e) (show-exp (:else e) (inc d) esc))))

(defmethod show-node :while [e d esc]
  (cons (indent d "while") (kids d esc [(:test e) (:body e)])))

(defmethod show-node :for [e d esc]
  (cons (indent d (str "for " (:binder e) (escapes-mark esc (:sym e))))
        (kids d esc [(:lo e) (:hi e) (:body e)])))

(defmethod show-node :break [e d _] [(indent d "break")])

(defmethod show-node :seq [e d esc]
  (cons (indent d (str "seq" (shown-type e))) (kids d esc (:items e))))

(defmethod show-node :let [e d esc]
  (concat [(indent d (str "let" (shown-type e)))]
          (mapcat #(show-decl % (inc d) esc) (:decls e))
          [(indent d "in")]
          (show-exp (:body e) (inc d) esc)))

(defmulti ^:private show-decl (fn [d _depth _escapes] (:decl d)))

(defmethod show-decl :type [d depth _]
  (map (fn [b] (indent depth (str "type " (:name b)))) (:binds d)))

(defmethod show-decl :val [d depth esc]
  (cons (indent depth (str (if (:var? d) "var" "val") " " (or (:name d) "()")
                           (escapes-mark esc (:sym d))))
        (show-exp (:init d) (inc depth) esc)))

(defmethod show-decl :fun [d depth esc]
  (mapcat (fn [b]
            (let [params (str/join ", " (map (fn [p] (str (:name p)
                                                          (escapes-mark esc (:sym p))))
                                             (:params b)))
                  result (if (:sym b) (ty/show-ty (:result (:sym b))) "?")]
              (cons (indent depth (str "fun " (:label b) "(" params ") : " result))
                    (show-exp (:body b) (inc depth) esc))))
          (:binds d)))

(defn show-program [prog escapes]
  (str (str/join "\n" (mapcat #(show-decl % 0 escapes) prog)) "\n"))

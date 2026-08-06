(ns wolv.parser
  "A Pratt parser.

  Every expression form is either a prefix form (in `parse-atom`) or an infix
  one (in `parse-exp`), and the table below is the whole of the precedence.  The
  prefix forms that end in an expression — `if`, `while`, `for`, `:=` — take
  their tail at binding power 0, so `if c then x := 1 else x := 2` reads the way
  it looks.

  A parser is a cursor over the tokens, and a cursor here is a value: every
  rule takes one and answers `[cursor node]`, which destructuring in a `let` is
  what threads."
  (:require [wolv.ast :as ast]
            [wolv.diag :as diag]
            [wolv.i64 :as i64]
            [wolv.lexer :as lexer]))

(def ^:private binding-powers
  "The left binding power and the power the right side is read at.  Left < right
  is left-associative; left > right is right-associative, which only `:=` is."
  {:ASSIGN [2 1]
   :ORELSE [4 5]
   :ANDALSO [6 7]
   :EQ [8 9] :NE [8 9] :LT [8 9] :LE [8 9] :GT [8 9] :GE [8 9]
   :CARET [10 11]
   :PLUS [12 13] :MINUS [12 13]
   :STAR [14 15] :SLASH [14 15] :MOD [14 15]})

(def ^:private unary-bp 16)

(def ^:private binops
  {:PLUS "+" :MINUS "-" :STAR "*" :SLASH "/" :MOD "mod" :CARET "^"
   :EQ "=" :NE "<>" :LT "<" :LE "<=" :GT ">" :GE ">="})

(defn- declares? [kind] (contains? #{:VAL :VAR :FUN :TYPE} kind))

;; -- token plumbing ----------------------------------------------------------

(defn- parser [toks] {:toks (vec toks) :pos 0})

(defn- cur [p] (nth (:toks p) (:pos p)))
(defn- kind [p] (:kind (cur p)))
(defn- at? [p k] (= (kind p) k))
(defn- bump [p] (update p :pos inc))
(defn- took
  "The cursor past `k`, or nil if that is not what is there."
  [p k]
  (when (at? p k) (bump p)))

(defn- found
  "What an error message calls the token that was found."
  [p]
  (let [t (cur p)]
    (case (:kind t)
      :EOF "end of input"
      :STRING (str "\"" (:text t) "\"")
      (str "`" (:text t) "`"))))

(defn- expect [p k]
  (if-let [p' (took p k)]
    [p' (cur p)]
    (diag/parse-error (:at (cur p))
                      (str "expected `" (lexer/kind-text k) "`, found " (found p)))))

(defn- expect-ident [p]
  (if-let [p' (took p :IDENT)]
    [p' (cur p)]
    (diag/parse-error (:at (cur p)) (str "expected a name, found " (found p)))))

;; -- expressions -------------------------------------------------------------

(declare ^:private parse-exp parse-atom parse-decl parse-ty)

(defn- check-lvalue [e]
  (when-not (ast/place? e)
    (diag/parse-error (:at e) "the left of `:=` is not assignable")))

(defn- integer-of
  "Integers are 64 bits and wrap, so the largest literal is the one written
  `~9223372036854775808`."
  [t]
  (let [v (try (bigint (:text t)) (catch Exception _ nil))]
    (when-not (and v (not (neg? v)) (< v 18446744073709551616N))
      (diag/parse-error (:at t) (str "`" (:text t) "` does not fit in 64 bits")))
    (i64/wrap v)))

(defn- parse-exp [p min-bp]
  (loop [[p left] (parse-atom p)]
    (let [powers (binding-powers (kind p))]
      (if (and powers (>= (first powers) min-bp))
        (let [t (cur p)
              rbp (second powers)
              p (bump p)]
          (when (= (:kind t) :ASSIGN) (check-lvalue left))
          (let [[p right] (parse-exp p rbp)
                at (:at t)
                node (case (:kind t)
                       :ASSIGN (ast/e-assign at left right)
                       (:ANDALSO :ORELSE) (ast/e-logic at (:text t) left right)
                       (ast/e-bin at (binops (:kind t)) left right))]
            (recur [p node])))
        [p left]))))

;; A trailing `;` is allowed, which is what the `stop` test is for.
(defn- parse-sequence [p stop]
  (loop [[p first-item] (parse-exp p 0) items []]
    (let [items (conj items first-item)]
      (if-let [p' (took p :SEMI)]
        (if (at? p' stop)
          [p' items]
          (recur (parse-exp p' 0) items))
        [p items]))))

(defn- comma-list
  "A comma-separated list already inside its brackets, up to `close`."
  [p close one]
  (if-let [p' (took p close)]
    [p' []]
    (loop [[p item] (one p) items []]
      (let [items (conj items item)]
        (if-let [p' (took p :COMMA)]
          (recur (one p') items)
          (let [[p _] (expect p close)] [p items]))))))

(defn- parse-parens [p]
  (let [[p lp] (expect p :LPAREN)
        start (:at lp)]
    (if-let [p' (took p :RPAREN)]
      [p' (ast/e-unit start)]
      (let [[p items] (parse-sequence p :RPAREN)
            [p _] (expect p :RPAREN)]
        [p (if (= 1 (count items)) (first items) (ast/e-seq start items))]))))

(defn- parse-named [p]
  (let [[p t] (expect-ident p)]
    (case (kind p)
      :LPAREN
      (let [[p args] (comma-list (bump p) :RPAREN #(parse-exp % 0))]
        [p (ast/e-call (:at t) (:text t) args)])

      :LBRACE
      (let [one (fn [p]
                  (let [[p fname] (expect-ident p)
                        [p _] (expect p :EQ)
                        [p value] (parse-exp p 0)]
                    [p (ast/field-init (:text fname) value (:at fname))]))
            [p inits] (comma-list (bump p) :RBRACE one)]
        [p (ast/e-record (:at t) (:text t) inits)])

      [p (ast/e-var (:at t) (:text t))])))

(defn- parse-postfix
  "`[i]` and `.f` follow an atom, and only an atom: `nil.f` is not an expression."
  [p base]
  (loop [p p out base]
    (let [start (:at (cur p))]
      (case (kind p)
        :LBRACK (let [[p index] (parse-exp (bump p) 0)
                      [p _] (expect p :RBRACK)]
                  (recur p (ast/e-index start out index)))
        :DOT (let [[p f] (expect-ident (bump p))]
               (recur p (ast/e-field start out (:text f))))
        [p out]))))

(defn- parse-if [p]
  (let [[p t] (expect p :IF)
        start (:at t)
        [p test] (parse-exp p 0)
        [p _] (expect p :THEN)
        [p then] (parse-exp p 0)]
    (if-let [p' (took p :ELSE)]
      (let [[p els] (parse-exp p' 0)] [p (ast/e-if start test then els)])
      [p (ast/e-if start test then nil)])))

(defn- parse-while [p]
  (let [[p t] (expect p :WHILE)
        [p test] (parse-exp p 0)
        [p _] (expect p :DO)
        [p body] (parse-exp p 0)]
    [p (ast/e-while (:at t) test body)]))

(defn- parse-for [p]
  (let [[p t] (expect p :FOR)
        [p binder] (expect-ident p)
        [p _] (expect p :EQ)
        [p lo] (parse-exp p 0)
        [p _] (expect p :TO)
        [p hi] (parse-exp p 0)
        [p _] (expect p :DO)
        [p body] (parse-exp p 0)]
    [p (ast/e-for (:at t) (:text binder) lo hi body)]))

(defn- parse-let [p]
  (let [[p t] (expect p :LET)
        start (:at t)
        [p decls] (loop [p p decls []]
                    (if (declares? (kind p))
                      (let [[p d] (parse-decl p)] (recur p (conj decls d)))
                      [p decls]))
        [p _] (expect p :IN)
        [p body] (if (at? p :END)
                   [p (ast/e-unit start)]
                   (let [[p items] (parse-sequence p :END)]
                     [p (if (= 1 (count items)) (first items) (ast/e-seq start items))]))
        [p _] (expect p :END)]
    [p (ast/e-let start decls body)]))

(defn- parse-atom [p]
  (let [t (cur p)
        start (:at t)]
    (case (:kind t)
      :INT (parse-postfix (bump p) (ast/e-int start (integer-of t)))
      :STRING (parse-postfix (bump p) (ast/e-str start (:text t)))
      (:TRUE :FALSE) [(bump p) (ast/e-bool start (= (:kind t) :TRUE))]
      :NIL [(bump p) (ast/e-nil start)]
      :BREAK [(bump p) (ast/e-break start)]
      :TILDE (let [[p operand] (parse-exp (bump p) unary-bp)]
               [p (ast/e-neg start operand)])
      :MINUS (diag/parse-error start "negation is written `~`, not `-`")
      :LPAREN (let [[p node] (parse-parens p)] (parse-postfix p node))
      :IDENT (let [[p node] (parse-named p)] (parse-postfix p node))
      :IF (parse-if p)
      :WHILE (parse-while p)
      :FOR (parse-for p)
      :LET (parse-let p)
      (diag/parse-error start (str "expected an expression, found " (found p))))))

;; -- types -------------------------------------------------------------------

(defn- parse-ty-atom [p start]
  (if-let [after-brace (took p :LBRACE)]
    (let [one (fn [p]
                (let [[p fname] (expect-ident p)
                      [p _] (expect p :COLON)
                      [p ty] (parse-ty p)]
                  [p (ast/ty-field (:text fname) ty (:at fname))]))
          [p fields] (comma-list after-brace :RBRACE one)]
      [p (ast/t-record start fields)])
    (if-let [after-paren (took p :LPAREN)]
      (let [[p inner] (parse-ty after-paren)
            [p _] (expect p :RPAREN)]
        [p inner])
      (let [[p t] (expect-ident p)] [p (ast/t-name start (:text t))]))))

(defn- parse-ty [p]
  (let [start (:at (cur p))]
    (loop [[p base] (parse-ty-atom p start)]
      (if (and (at? p :IDENT) (= (:text (cur p)) "array"))
        (recur [(bump p) (ast/t-array start base)])
        [p base]))))

;; -- declarations ------------------------------------------------------------

(defn- parse-group
  "`and` joins a group, and the group is one declaration: the names of a group
  are all in scope in all of its bodies."
  [p one]
  (loop [[p bind] (one p) binds []]
    (let [binds (conj binds bind)]
      (if-let [p' (took p :AND)]
        (recur (one p') binds)
        [p binds]))))

(defn- one-type-bind [p]
  (let [[p name] (expect-ident p)
        [p _] (expect p :EQ)
        [p bound] (parse-ty p)]
    [p (ast/type-bind (:text name) bound (:at name))]))

(defn- one-fun-bind [p]
  (let [[p name] (expect-ident p)
        [p _] (expect p :LPAREN)
        one (fn [p]
              (let [[p pname] (expect-ident p)
                    [p _] (expect p :COLON)
                    [p ty] (parse-ty p)]
                [p (ast/param (:text pname) ty (:at pname))]))
        [p params] (comma-list p :RPAREN one)
        [p result] (if-let [p' (took p :COLON)] (parse-ty p') [p nil])
        [p _] (expect p :EQ)
        [p body] (parse-exp p 0)]
    [p (ast/fun-bind (:text name) params result body (:at name))]))

(defn- parse-decl [p]
  (case (kind p)
    :TYPE (let [[p t] (expect p :TYPE)
                [p binds] (parse-group p one-type-bind)]
            [p (ast/d-type (:at t) binds)])

    (:VAL :VAR)
    (let [var? (at? p :VAR)
          start (:at (cur p))
          p (bump p)
          [p name] (if-let [p' (took p :LPAREN)]
                     (let [[p _] (expect p' :RPAREN)] [p nil])
                     (let [[p t] (expect-ident p)] [p (:text t)]))
          [p written] (if-let [p' (took p :COLON)] (parse-ty p') [p nil])
          [p _] (expect p :EQ)
          [p init] (parse-exp p 0)]
      [p (ast/d-val start name written init var?)])

    :FUN (let [[p t] (expect p :FUN)
               [p binds] (parse-group p one-fun-bind)]
           [p (ast/d-fun (:at t) binds)])

    (diag/parse-error (:at (cur p))
                      (str "expected a declaration (`val`, `var`, `fun`, `type`), found "
                           (found p)))))

;; -- entry points ------------------------------------------------------------

(defn parse [source]
  (loop [p (parser (lexer/lex source)) decls []]
    (if (at? p :EOF)
      decls
      (let [[p d] (parse-decl p)] (recur p (conj decls d))))))

(defn parse-one-exp
  "One expression — the tests use this, the compiler does not."
  [source]
  (let [[p e] (parse-exp (parser (lexer/lex source)) 0)]
    (when-not (at? p :EOF)
      (diag/parse-error (:at (cur p)) (str "unexpected " (found p) " after the expression")))
    e))

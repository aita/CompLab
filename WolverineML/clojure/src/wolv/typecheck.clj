(ns wolv.typecheck
  "The type checker, which also decides which variables escape.

  Types are monomorphic and there is nothing to infer but the type of a `val`.
  A `fun` without a result type is a procedure and returns `unit`, which is what
  makes recursion checkable without inference: every function's signature is
  known before any body is.

  The pass has a second job.  A variable read from inside a function nested more
  deeply than the one that binds it cannot live in a register, because the inner
  function reaches it through a static link at run time.  Every lookup that
  crosses a function boundary notes the variable as escaping, and the lowering
  pass gives those a frame slot instead.

  Every other port writes both answers onto the tree it was given.  Nothing here
  can be written on, so `check` answers with a second tree — `assoc` is the whole
  of that — and with the set of variables that escaped beside it."
  (:require [clojure.string :as str]
            [wolv.ast :as ast]
            [wolv.diag :as diag]
            [wolv.types :as ty]))

(def ^:private builtins
  "name, argument types, result, the symbol the runtime calls it"
  [["print" [:string] :unit "wol_print"]
   ["println" [:string] :unit "wol_println"]
   ["printInt" [:int] :unit "wol_print_int"]
   ["flush" [] :unit "wol_flush"]
   ["getChar" [] :string "wol_getchar"]
   ["ord" [:string] :int "wol_ord"]
   ["chr" [:int] :string "wol_chr"]
   ["size" [:string] :int "wol_size"]
   ["substring" [:string :int :int] :string "wol_substring"]
   ["concat" [:string :string] :string "wol_concat"]
   ["intToString" [:int] :string "wol_int_to_string"]
   ["stringToInt" [:string] :int "wol_string_to_int"]
   ["exit" [:int] :unit "wol_exit"]])

(def ^:private specials
  "The three whose types depend on their arguments, so the checker types them."
  ["array" "length" "not"])

(def ^:private arithmetic #{"+" "-" "*" "/" "mod"})
(def ^:private ordering #{"<" "<=" ">" ">="})
(def ^:private equality #{"=" "<>"})

(defn- prelude []
  {:tys (into {} (map (fn [t] [(name t) t]) [:int :string :bool :unit]))
   :vals (into {}
               (concat
                (map-indexed
                 (fn [i [nm args result symbol]]
                   [nm (ty/fun-sym nm symbol
                                   (map-indexed (fn [j a]
                                                  (ty/var-sym (- -1 (+ (* 8 i) j))
                                                              (str "a" j) a false 0))
                                                args)
                                   result 0 symbol)])
                 builtins)
                (map (fn [nm] [nm (ty/fun-sym nm nm [] :unit 0 nm)]) specials)))})

(defn- new-checker []
  {:scopes (list (prelude))
   :depth 0
   :loops 0
   :labels {}
   :records {}
   :next-record 0
   :next-var 0
   :escapes #{}})

;; -- scopes ------------------------------------------------------------------

(defn- push-scope [ck] (update ck :scopes conj {:tys {} :vals {}}))
(defn- pop-scope [ck] (update ck :scopes rest))

(defn- bind-val [ck nm sym] (update ck :scopes (fn [[s & r]] (cons (assoc-in s [:vals nm] sym) r))))
(defn- bind-type [ck nm t] (update ck :scopes (fn [[s & r]] (cons (assoc-in s [:tys nm] t) r))))

(defn- lookup [ck pick nm at what]
  (or (first (keep #(get (pick %) nm) (:scopes ck)))
      (diag/type-error at (str "`" nm "` is not " what))))

(defn- lookup-val [ck nm at] (lookup ck :vals nm at "bound"))
(defn- lookup-type [ck nm at] (lookup ck :tys nm at "a type"))

(defn- unique-label
  "Two functions of the same name in one program need two labels."
  [ck nm]
  (let [n (get (:labels ck) nm 0)]
    [(assoc-in ck [:labels nm] (inc n))
     (if (zero? n) (str "wol_" nm) (str "wol_" nm "." n))]))

(defn- fresh-var [ck nm t mutable? depth]
  [(update ck :next-var inc) (ty/var-sym (:next-var ck) nm t mutable? depth)])

(defn- unify [want got at where]
  (when-not (ty/compatible? want got)
    (diag/type-error at (str "expected `" (ty/show-ty want) "`, found `"
                             (ty/show-ty got) "` " where))))

(defn- fields-of [ck t] (get (:records ck) (:id t)))

(defn- thread
  "`f` over `xs`, threading the checker through and collecting what came back."
  [f ck xs]
  (reduce (fn [[ck done] x] (let [[ck y] (f ck x)] [ck (conj done y)])) [ck []] xs))

;; -- types as they are written -----------------------------------------------

(defn- resolve-ty [ck t]
  (case (:ty-node t)
    :name (lookup-type ck (:name t) (:at t))
    :array (ty/array-type (resolve-ty ck (:elem t)))
    :record (diag/type-error (:at t) "a record type has to be given a name by `type`")))

;; -- expressions -------------------------------------------------------------

(declare ^:private infer check-decl)

(defmulti ^:private infer-node
  "What type this node has, the node with its children checked, and the checker
  state that came out.  One method per form; the dispatch is on `:op`."
  (fn [_ck e] (:op e)))

(defn- infer [ck e]
  (let [[ck e t] (infer-node ck e)]
    [ck (assoc e :ty t) t]))

(defn- infer-in
  "Check the expression under `k` and put it back where it came from."
  [ck e k]
  (let [[ck sub t] (infer ck (get e k))]
    [ck (assoc e k sub) t]))

(defmethod infer-node :int [ck e] [ck e :int])
(defmethod infer-node :str [ck e] [ck e :string])
(defmethod infer-node :bool [ck e] [ck e :bool])
(defmethod infer-node :nil [ck e] [ck e :nil])
(defmethod infer-node :unit [ck e] [ck e :unit])

(defmethod infer-node :var [ck e]
  (let [sym (lookup-val ck (:name e) (:at e))]
    (when (ty/fun-sym? sym)
      (diag/type-error (:at e)
                       (str "`" (:name e) "` is a function, and functions are not values")))
    ;; Read from deeper than it was bound: it cannot live in a register.
    [(if (< (:depth sym) (:depth ck)) (update ck :escapes conj (:id sym)) ck)
     (assoc e :sym sym)
     (:ty sym)]))

(defn- arity [e callee args want]
  (when-not (= (count args) want)
    (diag/type-error (:at e)
                     (str "`" callee "` takes " want " argument" (if (= want 1) "" "s")
                          ", given " (count args)))))

(defn- infer-all
  "Check a sequence of expressions in order, and answer with them and their types."
  [ck es]
  (reduce (fn [[ck done] e]
            (let [[ck e' _] (infer ck e)] [ck (conj done e')]))
          [ck []] es))

(defmethod infer-node :call [ck e]
  (let [callee (:callee e)
        f (lookup-val ck callee (:at e))]
    (when (ty/var-sym? f)
      (diag/type-error (:at e) (str "`" callee "` is a variable, not a function")))
    (let [e (assoc e :sym f)
          args (:args e)]
      (case (:builtin f)
        "array"
        (do (arity e callee args 2)
            (let [[ck args] (infer-all ck args)]
              (unify :int (:ty (first args)) (:at (first args)) "as an array length")
              (let [elem (:ty (second args))]
                (when (= elem :nil)
                  (diag/type-error (:at (second args))
                                   "`array` cannot tell which record `nil` stands for"))
                [ck (assoc e :args args) (ty/array-type elem)])))

        "length"
        (do (arity e callee args 1)
            (let [[ck args] (infer-all ck args)
                  got (:ty (first args))]
              (when-not (ty/array-type? got)
                (diag/type-error (:at (first args))
                                 (str "`length` wants an array, found `" (ty/show-ty got) "`")))
              [ck (assoc e :args args) :int]))

        "not"
        (do (arity e callee args 1)
            (let [[ck args] (infer-all ck args)]
              (unify :bool (:ty (first args)) (:at e) "in a call to `not`")
              [ck (assoc e :args args) :bool]))

        (do (arity e callee args (count (:params f)))
            (let [[ck args] (infer-all ck args)]
              (doseq [[a p] (map vector args (:params f))]
                (unify (:ty p) (:ty a) (:at a) (str "in a call to `" callee "`")))
              [ck (assoc e :args args) (:result f)]))))))

(defmethod infer-node :record [ck e]
  (let [tyname (:tyname e)
        found (lookup-type ck tyname (:at e))]
    (when-not (ty/record-type? found)
      (diag/type-error (:at e) (str "`" tyname "` is not a record type")))
    (let [fields (fields-of ck found)]
      (reduce (fn [seen f]
                (when (contains? seen (:name f))
                  (diag/type-error (:at f) (str "field `" (:name f) "` is given twice")))
                (when (neg? (ty/record-index fields (:name f)))
                  (diag/type-error (:at f)
                                   (str "`" (:name found) "` has no field `" (:name f) "`")))
                (conj seen (:name f)))
              #{} (:inits e))
      ;; The initialisers are put into declaration order, which is what lowering
      ;; wants.
      (let [by-name (into {} (map (fn [f] [(:name f) f]) (:inits e)))
            [ck inits]
            (reduce (fn [[ck done] [fname fty]]
                      (let [init (get by-name fname)]
                        (when-not init
                          (diag/type-error (:at e) (str "field `" fname "` is missing")))
                        (let [[ck value t] (infer ck (:value init))]
                          (unify fty t (:at init) (str "in field `" fname "`"))
                          [ck (conj done (assoc init :value value))])))
                    [ck []] fields)]
        [ck (assoc e :inits inits) found]))))

(defmethod infer-node :index [ck e]
  (let [[ck e got] (infer-in ck e :array)]
    (when-not (ty/array-type? got)
      (diag/type-error (:at e) (str "`" (ty/show-ty got) "` is not an array")))
    (let [[ck e it] (infer-in ck e :index)]
      (unify :int it (:at (:index e)) "as an array index")
      [ck e (:elem got)])))

(defmethod infer-node :field [ck e]
  (let [[ck e got] (infer-in ck e :record)]
    (when-not (ty/record-type? got)
      (diag/type-error (:at e) (str "`" (ty/show-ty got) "` is not a record")))
    (let [fields (fields-of ck got)
          t (ty/record-field-type fields (:select e))]
      (when-not t
        (diag/type-error (:at e)
                         (str "`" (:name got) "` has no field `" (:select e) "`")))
      [ck (assoc e :offset (ty/record-index fields (:select e))) t])))

(defmethod infer-node :neg [ck e]
  (let [[ck e t] (infer-in ck e :operand)]
    (unify :int t (:at e) "in a negation")
    [ck e :int]))

(defmethod infer-node :bin [ck e]
  (let [op (:oper e)
        [ck e l] (infer-in ck e :lhs)
        [ck e r] (infer-in ck e :rhs)
        lhs (:lhs e) rhs (:rhs e)]
    (cond
      (arithmetic op)
      (do (unify :int l (:at lhs) (str "on the left of `" op "`"))
          (unify :int r (:at rhs) (str "on the right of `" op "`"))
          [ck e :int])

      (= op "^")
      (do (unify :string l (:at lhs) "on the left of `^`")
          (unify :string r (:at rhs) "on the right of `^`")
          [ck e :string])

      (ordering op)
      (do (when-not (contains? #{:int :string} l)
            (diag/type-error (:at e)
                             (str "`" op "` compares int or string, not `" (ty/show-ty l) "`")))
          (unify l r (:at rhs) (str "on the right of `" op "`"))
          [ck e :bool])

      (equality op)
      (do (when (or (= l :unit) (= r :unit))
            (diag/type-error (:at e) (str "`" op "` cannot compare `unit`")))
          (when-not (ty/compatible? l r)
            (diag/type-error (:at e) (str "`" op "` compares `" (ty/show-ty l)
                                          "` with `" (ty/show-ty r) "`")))
          [ck e :bool])

      :else (diag/type-error (:at e) (str "unknown operator `" op "`")))))

(defmethod infer-node :logic [ck e]
  (let [op (:oper e)
        [ck e l] (infer-in ck e :lhs)
        [ck e r] (infer-in ck e :rhs)]
    (unify :bool l (:at (:lhs e)) (str "on the left of `" op "`"))
    (unify :bool r (:at (:rhs e)) (str "on the right of `" op "`"))
    [ck e :bool]))

(defmethod infer-node :assign [ck e]
  (let [[ck e t] (infer-in ck e :target)
        target (:target e)]
    (when (= (:op target) :var)
      (let [sym (:sym target)]
        (when-not (:mutable? sym)
          (diag/type-error (:at e)
                           (str "`" (:name sym) "` is a `val`, so it cannot be assigned")))))
    (let [[ck e vt] (infer-in ck e :value)]
      (unify t vt (:at (:value e)) "in an assignment")
      [ck e :unit])))

(defmethod infer-node :if [ck e]
  (let [[ck e ct] (infer-in ck e :test)]
    (unify :bool ct (:at (:test e)) "as an `if` condition")
    (let [[ck e t] (infer-in ck e :then)]
      (if-not (:else e)
        (do (unify :unit t (:at (:then e)) "in an `if` with no `else`")
            [ck e :unit])
        (let [[ck e other] (infer-in ck e :else)]
          (when-not (ty/compatible? t other)
            (diag/type-error (:at e) (str "the branches differ: `" (ty/show-ty t)
                                          "` and `" (ty/show-ty other) "`")))
          [ck e (if (= t :nil) other t)])))))

(defmethod infer-node :while [ck e]
  (let [[ck e ct] (infer-in ck e :test)]
    (unify :bool ct (:at (:test e)) "as a `while` condition")
    (let [[ck e bt] (infer-in (update ck :loops inc) e :body)]
      (unify :unit bt (:at (:body e)) "in a `while` body")
      [(update ck :loops dec) e :unit])))

(defmethod infer-node :for [ck e]
  (let [[ck e lo] (infer-in ck e :lo)]
    (unify :int lo (:at (:lo e)) "as a `for` bound")
    (let [[ck e hi] (infer-in ck e :hi)]
      (unify :int hi (:at (:hi e)) "as a `for` bound")
      (let [[ck sym] (fresh-var ck (:binder e) :int false (:depth ck))
            e (assoc e :sym sym)
            ck (-> ck push-scope (bind-val (:binder e) sym) (update :loops inc))
            [ck e bt] (infer-in ck e :body)]
        (unify :unit bt (:at (:body e)) "in a `for` body")
        [(-> ck (update :loops dec) pop-scope) e :unit]))))

(defmethod infer-node :break [ck e]
  (when (zero? (:loops ck)) (diag/type-error (:at e) "`break` is outside any loop"))
  [ck e :unit])

(defmethod infer-node :seq [ck e]
  (let [[ck items] (infer-all ck (:items e))]
    [ck (assoc e :items items) (if (seq items) (:ty (last items)) :unit)]))

(defmethod infer-node :let [ck e]
  (let [[ck decls] (thread check-decl (push-scope ck) (:decls e))
        e (assoc e :decls decls)
        [ck e t] (infer-in ck e :body)]
    [(pop-scope ck) e t]))

;; -- declarations ------------------------------------------------------------

(defmulti ^:private check-decl (fn [_ck d] (:decl d)))

(defmethod check-decl :type [ck d]
  ;; Records are bound before any field is resolved, so a group of `type`s may
  ;; name each other and itself.
  (let [binds (:binds d)
        [ck made] (reduce (fn [[ck made] b]
                            (if (= (:ty-node (:bound b)) :record)
                              (let [t (ty/record-type (:name b) (:next-record ck))
                                    ck (-> ck (update :next-record inc)
                                           (bind-type (:name b) t))]
                                [ck (conj made [t (:fields (:bound b))])])
                              [ck made]))
                          [ck []] binds)
        ck (reduce (fn [ck b]
                     (if (= (:ty-node (:bound b)) :record)
                       ck
                       (bind-type ck (:name b) (resolve-ty ck (:bound b)))))
                   ck binds)
        ck (reduce (fn [ck [t fields]]
                     (reduce (fn [seen f]
                               (when (contains? seen (:name f))
                                 (diag/type-error (:at f)
                                                  (str "duplicate field `" (:name f) "`")))
                               (conj seen (:name f)))
                             #{} fields)
                     (assoc-in ck [:records (:id t)]
                               (mapv (fn [f] [(:name f) (resolve-ty ck (:ty f))]) fields)))
                   ck made)]
    [ck d]))

(defmethod check-decl :val [ck d]
  (let [[ck init got0] (infer ck (:init d))
        d (assoc d :init init)
        got (if-let [written (:written d)]
              (let [want (resolve-ty ck written)]
                (unify want got0 (:at init) "in this binding")
                want)
              got0)]
    (if-not (:name d)
      (do (unify :unit got (:at init) "in `val () =`")
          [ck d])
      (do (when (= got :nil)
            (diag/type-error (:at d)
                             (str "`" (:name d) "` needs a type annotation to hold `nil`")))
          (let [[ck sym] (fresh-var ck (:name d) got (:var? d) (:depth ck))]
            [(bind-val ck (:name d) sym) (assoc d :sym sym)])))))

(defn- signature
  "One binding of the group, with its parameters and its symbol worked out."
  [ck b]
  (let [[ck _ params]
        (reduce (fn [[ck seen ps] p]
                  (when (contains? seen (:name p))
                    (diag/type-error (:at p) (str "duplicate parameter `" (:name p) "`")))
                  (let [[ck sym] (fresh-var ck (:name p) (resolve-ty ck (:ty p))
                                            false (inc (:depth ck)))]
                    [ck (conj seen (:name p)) (conj ps (assoc p :sym sym))]))
                [ck #{} []] (:params b))
        result (if (:result b) (resolve-ty ck (:result b)) :unit)
        [ck label] (unique-label ck (:label b))
        sym (ty/fun-sym (:label b) label (mapv :sym params) result (inc (:depth ck)) nil)]
    [(bind-val ck (:label b) sym) (assoc b :params params :sym sym)]))

(defn- body-of
  "One binding's body, checked one level deeper and outside any loop."
  [ck b]
  (let [outer (:loops ck)
        inner (reduce (fn [ck p] (bind-val ck (:name p) (:sym p)))
                      (-> ck (update :depth inc) (assoc :loops 0) push-scope)
                      (:params b))
        [inner body t] (infer inner (:body b))]
    (unify (:result (:sym b)) t (:at body) (str "in the body of `" (:label b) "`"))
    [(-> inner pop-scope (assoc :loops outer) (update :depth dec))
     (assoc b :body body)]))

(defmethod check-decl :fun [ck d]
  ;; Every signature in the group is bound before any body is typed.
  (let [[ck binds] (thread signature ck (:binds d))
        [ck binds] (thread body-of ck binds)]
    [ck (assoc d :binds binds)]))

(defn check
  "Types the program, and answers with the typed tree and what escaped."
  [prog]
  (let [[ck decls] (thread check-decl (push-scope (new-checker)) prog)]
    {:program decls :escapes (:escapes ck)}))

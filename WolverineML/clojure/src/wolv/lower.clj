(ns wolv.lower
  "Lowering: the typed syntax tree becomes a control flow graph.

  Two things are worth knowing about this pass.

  It never builds a phi.  A variable written in two branches is written to the
  same register twice, and `ssa.clj` is what turns those two writes into one
  phi.  Lowering only has to make sure a definition reaches every use, which
  structured control flow does for free.

  It decides where a variable lives.  A variable the checker did not note as
  escaping becomes a register; one that escaped becomes a frame slot, reached
  through `:load-slot`/`:store-slot` in its own function and through a chain of
  static links from a nested one.  Where each ended up is a table from the
  variable's number, because a symbol is a value here and cannot be written on.

  This is the one pass that builds rather than transforms, so it threads a state
  — the function being filled, which block is being filled, the module around
  it — and every rule answers `[state register]`."
  (:require [wolv.ast :as ast]
            [wolv.ir :as ir]
            [wolv.types :as ty]))

(defn options
  ([] (options true))
  ([checks?] {:checks? checks?}))

;; -- the state ---------------------------------------------------------------

(defn- reg [st]
  (let [[f r] (ir/new-reg (:func st))] [(assoc st :func f) r]))

(defn- slot [st]
  (let [[f s] (ir/new-slot (:func st))] [(assoc st :func f) s]))

(defn- put [st i] (update st :func #(ir/emit % (:cur st) i)))

(defn- fresh [st hint]
  (let [label (str hint (inc (:counter st)))]
    [(-> st (update :counter inc) (update :func #(ir/add-block % label))) label]))

(defn- terminate [st t]
  (let [[st dead] (fresh (put st t) "dead")]
    (assoc st :cur dead)))

(defn- jump [st label] (terminate st (ir/i-jmp label)))

(defn- branch [st cnd yes no] (terminate st (ir/i-cbr cnd yes no "")))

(defn- constant [st value]
  (let [[st r] (reg st)] [(put st (ir/i-const r value)) r]))

(defn- binop [st oper lhs rhs]
  (let [[st r] (reg st)] [(put st (ir/i-bin r oper lhs rhs)) r]))

(defn- compare-into [st oper lhs rhs]
  (let [[st r] (reg st)] [(put st (ir/i-cmp r oper lhs rhs)) r]))

(defn- call-runtime [st name args]
  (let [[st r] (reg st)] [(put st (ir/i-call r name args)) r]))

(defn- intern-string
  "String literals, the same text emitted once."
  [st text]
  (if-let [found (get-in st [:mod :symbols text])]
    [st found]
    (let [symbol (str ".Lstr" (count (get-in st [:mod :symbols])))]
      [(-> st
           (assoc-in [:mod :symbols text] symbol)
           (update-in [:mod :strings] conj {:symbol symbol :text text}))
       symbol])))

(defn- escapes? [st sym] (contains? (:escapes st) (:id sym)))
(defn- home [st sym] (get (:homes st) (:id sym)))

;; -- reaching variables and frames -------------------------------------------

(defn- frame-at
  "A register holding the frame pointer of the function at `depth`."
  [st depth]
  (let [here (get-in st [:func :depth])
        [st r] (reg st)]
    (if (= depth here)
      [(put st (ir/i-frame-addr r)) r]
      (loop [st (put st (ir/i-load-slot r (get-in st [:func :link-slot])))
             r r
             level (dec here)]
        (if (<= level depth)
          [st r]
          (let [[st next] (reg st)]
            (recur (put st (ir/i-load next r (ir/slot-offset 0))) next (dec level))))))))

(defn- read-var [st sym]
  (cond
    (not (escapes? st sym)) [st (:reg (home st sym))]

    (= (:depth sym) (get-in st [:func :depth]))
    (let [[st r] (reg st)]
      [(put st (ir/i-load-slot r (:slot (home st sym)))) r])

    :else
    (let [[st base] (frame-at st (:depth sym))
          [st r] (reg st)]
      [(put st (ir/i-load r base (ir/slot-offset (:slot (home st sym))))) r])))

(defn- write-var [st sym value]
  (cond
    (not (escapes? st sym)) (put st (ir/i-move (:reg (home st sym)) value))

    (= (:depth sym) (get-in st [:func :depth]))
    (put st (ir/i-store-slot (:slot (home st sym)) value))

    :else
    (let [[st base] (frame-at st (:depth sym))]
      (put st (ir/i-store base (ir/slot-offset (:slot (home st sym))) value)))))

(defn- bind-var
  "Give a variable its home, and put the initial value in it."
  [st sym value]
  (if (escapes? st sym)
    (let [[st s] (slot st)]
      (-> st
          (assoc-in [:homes (:id sym)] (ty/in-frame s))
          (put (ir/i-store-slot s value))))
    (let [[st r] (reg st)]
      (-> st
          (assoc-in [:homes (:id sym)] (ty/in-register r))
          (put (ir/i-move r value))))))

;; -- run-time checks ---------------------------------------------------------

;; Each of the three is the same shape: a branch to a block that calls the
;; runtime and never comes back, and a block where the program carries on.
(defn- guard [st hint test-reg bad-first? call]
  (let [[st bad] (fresh st hint)
        [st ok] (fresh st "ok")
        st (if bad-first? (branch st test-reg bad ok) (branch st test-reg ok bad))]
    (-> st (assoc :cur bad) (put call) (jump ok) (assoc :cur ok))))

(defn- check-not-nil [st base]
  (if-not (:checks? (:opts st))
    st
    (let [[st zero] (constant st 0)
          [st test] (compare-into st "=" base zero)]
      (guard st "nil" test true (ir/i-call nil "wol_nil_error" [])))))

(defn- check-bounds [st base idx]
  (if-not (:checks? (:opts st))
    st
    (let [[st len] (reg st)
          st (put st (ir/i-load len base 0))
          [st test] (compare-into st "u<" idx len)]
      (guard st "oob" test false (ir/i-call nil "wol_bounds_error" [idx len])))))

(defn- check-nonzero [st rhs]
  (if-not (:checks? (:opts st))
    st
    (let [[st zero] (constant st 0)
          [st test] (compare-into st "=" rhs zero)]
      (guard st "divzero" test true (ir/i-call nil "wol_div_error" [])))))

;; -- expressions -------------------------------------------------------------

(declare ^:private lower-decls lower-function function-body)

(defmulti ^:private lower-exp
  "The register the value ended up in, or nil for a form with no value."
  (fn [_st e] (:op e)))

(defn- value [st e]
  (let [[st r] (lower-exp st e)]
    (when-not r (throw (ex-info "expected a value here" {})))
    [st r]))

(defn- lower-all [st es]
  (reduce (fn [[st done] e] (let [[st r] (value st e)] [st (conj done r)]))
          [st []] es))

(defmethod lower-exp :int [st e] (constant st (:value e)))
(defmethod lower-exp :bool [st e] (constant st (if (:value e) 1 0)))
(defmethod lower-exp :nil [st _] (constant st 0))
(defmethod lower-exp :unit [st _] [st nil])

(defmethod lower-exp :str [st e]
  (let [[st symbol] (intern-string st (:value e))
        [st r] (reg st)]
    [(put st (ir/i-str-const r symbol)) r]))

(defmethod lower-exp :var [st e] (read-var st (:sym e)))

(defn- element-address
  "The address of `a[i]`, without the length word the elements follow.

  The selector turns this into one `add` with a shifted operand, and the word is
  the load's displacement, so the two instructions that come out are the two the
  machine has."
  [st array index]
  (let [[st base] (value st array)
        [st idx] (value st index)
        st (check-not-nil st base)
        st (check-bounds st base idx)
        [st three] (constant st 3)
        [st shifted] (binop st "shl" idx three)]
    (binop st "+" base shifted)))

(defmethod lower-exp :index [st e]
  (let [[st addr] (element-address st (:array e) (:index e))
        [st r] (reg st)]
    [(put st (ir/i-load r addr ir/WORD)) r]))

(defmethod lower-exp :field [st e]
  (let [[st base] (value st (:record e))
        st (check-not-nil st base)
        [st r] (reg st)]
    [(put st (ir/i-load r base (* ir/WORD (:offset e)))) r]))

(defmethod lower-exp :neg [st e]
  (let [[st zero] (constant st 0)
        [st v] (value st (:operand e))]
    (binop st "-" zero v)))

(defmethod lower-exp :break [st _]
  [(terminate st (ir/i-jmp (first (:breaks st)))) nil])

(defmethod lower-exp :seq [st e]
  (reduce (fn [[st _] item] (lower-exp st item)) [st nil] (:items e)))

(defmethod lower-exp :let [st e]
  (lower-exp (lower-decls st (:decls e)) (:body e)))

(defmethod lower-exp :bin [st e]
  (let [oper (:oper e)
        [st lhs] (value st (:lhs e))
        [st rhs] (value st (:rhs e))]
    (cond
      (= oper "^") (call-runtime st "wol_concat" [lhs rhs])

      (contains? #{"/" "mod"} oper)
      (let [st (check-nonzero st rhs)]
        (if (= oper "/")
          (binop st "/" lhs rhs)
          ;; The remainder is spelled out rather than left to the emitter: the
          ;; quotient it needs in between is a value like any other, and the
          ;; allocator can find it a register.  The emitter fuses the last two
          ;; back into one `msub`.
          (let [[st q] (binop st "/" lhs rhs)
                [st p] (binop st "*" q rhs)]
            (binop st "-" lhs p))))

      (contains? #{"+" "-" "*"} oper) (binop st oper lhs rhs)

      (= (:ty (:lhs e)) :string)
      (let [[st order] (call-runtime st "wol_string_cmp" [lhs rhs])
            [st zero] (constant st 0)]
        (compare-into st oper order zero))

      :else (compare-into st oper lhs rhs))))

;; `andalso` and `orelse` are branches, so the result needs a register.
(defmethod lower-exp :logic [st e]
  (let [[st result] (reg st)
        [st rhs-block] (fresh st "logic")
        [st join] (fresh st "logicjoin")
        [st lhs] (value st (:lhs e))
        st (put st (ir/i-move result lhs))
        st (if (= (:oper e) "andalso")
             (branch st lhs rhs-block join)
             (branch st lhs join rhs-block))
        st (assoc st :cur rhs-block)
        [st r] (value st (:rhs e))
        st (-> st (put (ir/i-move result r)) (jump join) (assoc :cur join))]
    [st result]))

(defmethod lower-exp :call [st e]
  (let [sym (:sym e)
        args (:args e)]
    (case (:builtin sym)
      "not" (let [[st a] (value st (first args))
                  [st one] (constant st 1)]
              (binop st "xor" a one))

      "array" (let [[st n] (value st (first args))
                    [st init] (value st (second args))]
                (call-runtime st "wol_array" [n init]))

      "length" (let [[st arr] (value st (first args))
                     st (check-not-nil st arr)
                     [st r] (reg st)]
                 [(put st (ir/i-load r arr 0)) r])

      (let [[st lowered] (lower-all st args)
            [st full] (if (:builtin sym)
                        [st lowered]
                        (let [[st link] (frame-at st (dec (:depth sym)))]
                          [st (into [link] lowered)]))]
        (if (= (:result sym) :unit)
          [(put st (ir/i-call nil (:label sym) full)) nil]
          (call-runtime st (:label sym) full))))))

(defmethod lower-exp :record [st e]
  (let [n (max (count (:inits e)) 1)
        [st size] (constant st (* ir/WORD n))
        [st base] (call-runtime st "wol_alloc" [size])
        st (reduce (fn [st [i f]]
                     (let [[st v] (value st (:value f))]
                       (put st (ir/i-store base (* ir/WORD i) v))))
                   st (map-indexed vector (:inits e)))]
    [st base]))

(defmethod lower-exp :if [st e]
  (let [[st result] (if (= (:ty e) :unit) [st nil] (reg st))
        [st yes] (fresh st "then")
        [st no] (fresh st "else")
        [st join] (fresh st "join")
        copy-into (fn [st branch-exp]
                    (let [[st v] (lower-exp st branch-exp)]
                      (if (and result v) (put st (ir/i-move result v)) st)))
        [st cnd] (value st (:test e))
        st (branch st cnd yes no)
        st (-> st (assoc :cur yes) (copy-into (:then e)) (jump join) (assoc :cur no))
        st (if (:else e) (copy-into st (:else e)) st)
        st (-> st (jump join) (assoc :cur join))]
    [st result]))

(defn- in-loop [st done body]
  (-> st (update :breaks conj done) body (update :breaks rest)))

(defmethod lower-exp :while [st e]
  (let [[st test] (fresh st "test")
        [st body] (fresh st "body")
        [st done] (fresh st "done")
        st (-> st (jump test) (assoc :cur test))
        [st cnd] (value st (:test e))
        st (-> st (branch cnd body done) (assoc :cur body))
        st (in-loop st done (fn [st] (first (lower-exp st (:body e)))))
        st (-> st (jump test) (assoc :cur done))]
    [st nil]))

;; `for i = lo to hi` counts up, and stops before overflowing at `hi`.
(defmethod lower-exp :for [st e]
  (let [sym (:sym e)
        [st lo] (value st (:lo e))
        [st hi-value] (value st (:hi e))
        [st hi] (reg st)
        st (put st (ir/i-move hi hi-value))
        st (bind-var st sym lo)
        [st body] (fresh st "forbody")
        [st step] (fresh st "forstep")
        [st done] (fresh st "fordone")
        [st test] (compare-into st "<=" lo hi)
        st (-> st (branch test body done) (assoc :cur body))
        st (in-loop st done (fn [st] (first (lower-exp st (:body e)))))
        [st i] (read-var st sym)
        [st again] (compare-into st "<" i hi)
        st (-> st (branch again step done) (assoc :cur step))
        [st i2] (read-var st sym)
        [st one] (constant st 1)
        [st next] (binop st "+" i2 one)
        st (-> (write-var st sym next) (jump body) (assoc :cur done))]
    [st nil]))

(defmulti ^:private assign-to (fn [_st target _v] (:op target)))

(defmethod assign-to :var [st target v]
  (let [[st r] (value st v)] (write-var st (:sym target) r)))

(defmethod assign-to :index [st target v]
  (let [[st addr] (element-address st (:array target) (:index target))
        [st r] (value st v)]
    (put st (ir/i-store addr ir/WORD r))))

(defmethod assign-to :field [st target v]
  (let [[st base] (value st (:record target))
        st (check-not-nil st base)
        [st r] (value st v)]
    (put st (ir/i-store base (* ir/WORD (:offset target)) r))))

(defmethod lower-exp :assign [st e]
  [(assign-to st (:target e) (:value e)) nil])

;; -- declarations ------------------------------------------------------------

(defmulti ^:private lower-decl (fn [_st d] (:decl d)))

(defmethod lower-decl :type [st _] st)

(defmethod lower-decl :val [st d]
  (let [[st value] (lower-exp st (:init d))
        sym (:sym d)]
    (if (and sym (not= (:ty sym) :unit))
      (bind-var st sym value)
      st)))

(defmethod lower-decl :fun [st d]
  (reduce (fn [st b]
            (let [sym (:sym b)]
              (lower-function st (:label sym) (:name sym) (:depth sym)
                              (fn [st] (function-body st b sym)))))
          (assoc st :children? true)
          (:binds d)))

(defn- lower-decls [st decls] (reduce lower-decl st decls))

;; -- whole functions ---------------------------------------------------------

(defn- bind-params [st psyms]
  (loop [st st
         psyms psyms
         index (count (get-in st [:func :params]))]
    (if (empty? psyms)
      st
      (let [psym (first psyms)]
        (if (>= index ir/ARGUMENT-REGISTERS)
          ;; The ninth argument and beyond is already in the frame when the
          ;; callee starts, at a negative slot, so it never takes a register.
          (recur (-> st
                     (update :escapes conj (:id psym))
                     (assoc-in [:homes (:id psym)]
                               (ty/in-frame (- (inc (- index ir/ARGUMENT-REGISTERS))))))
                 (rest psyms) (inc index))
          (let [[st r] (reg st)
                st (update-in st [:func :params] conj r)]
            (if (escapes? st psym)
              (let [[st s] (slot st)]
                (recur (-> st
                           (assoc-in [:homes (:id psym)] (ty/in-frame s))
                           (put (ir/i-store-slot s r)))
                       (rest psyms) (inc index)))
              (recur (assoc-in st [:homes (:id psym)] (ty/in-register r))
                     (rest psyms) (inc index)))))))))

(defn- function-body [st b sym]
  (let [depth (get-in st [:func :depth])
        st (if (pos? depth)
             (let [[st link] (reg st)
                   st (update-in st [:func :params] conj link)]
               (put st (ir/i-store-slot (get-in st [:func :link-slot]) link)))
             st)
        st (bind-params st (:params sym))
        [st value] (lower-exp st (:body b))]
    (terminate st (ir/i-ret (when (not= (:result sym) :unit) value)))))

(defn- drop-unused-link
  "A function nobody nests inside, and that never looks outward, keeps no static
  link: the slot goes, and every later slot moves down one."
  [st]
  (let [f (:func st)
        s (:link-slot f)
        moved #(if (> % s) (dec %) %)
        reads? (fn [i] (and (= (:op i) :load-slot) (= (:slot i) s)))
        stores? (fn [i] (and (= (:op i) :store-slot) (= (:slot i) s)))]
    (if (or (neg? s)
            (:children? st)
            (some (fn [b] (some reads? (ir/instrs b))) (ir/blocks f)))
      st
      (assoc st :func
             (-> (ir/map-blocks
                  f
                  (fn [b]
                    (update b :instrs
                            (fn [is]
                              (mapv (fn [i]
                                      (if (contains? #{:store-slot :load-slot} (:op i))
                                        (update i :slot moved)
                                        i))
                                    (filterv (complement stores?) is))))))
                 (update :nslots dec)
                 (assoc :link-slot -1))))))

(defn- lower-function
  "Build one function, in a place reserved for it: a nested function comes after
  the one it is nested in, which is the order it was created in."
  [st label name depth body]
  (let [at (count (get-in st [:mod :funcs]))
        outer (select-keys st [:func :cur :breaks :counter :children?])
        f (ir/add-block (ir/new-func label name depth) "entry")
        [f link] (if (pos? depth) (ir/new-slot f) [f nil])
        f (if link (assoc f :link-slot link) f)
        st (-> st
               (update-in [:mod :funcs] conj nil)
               (assoc :func f :cur "entry" :breaks () :counter 0 :children? false))
        st (body st)
        st (assoc st :func (ir/drop-unreachable (:func st)))
        st (drop-unused-link st)]
    (merge (assoc-in st [:mod :funcs at] (:func st)) outer)))

(defn lower
  ([prog escapes] (lower prog escapes (options)))
  ([prog escapes opts]
   (let [st {:opts opts :mod (assoc (ir/new-module) :symbols {})
             :homes {} :escapes escapes}
         st (lower-function st "wol_main" "main" 0
                            (fn [st] (terminate (lower-decls st prog) (ir/i-ret nil))))]
     {:funcs (get-in st [:mod :funcs]) :strings (get-in st [:mod :strings])})))

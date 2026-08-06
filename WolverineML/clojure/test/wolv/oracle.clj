(ns wolv.oracle
  "Random programs whose answer is known before they are compiled.

  The other tests say what the compiler should do; these say what the program
  should print, which is the only thing a user cares about.  A program is built
  at random, worked out here with the language's arithmetic, and then compiled —
  so any disagreement is a bug in the compiler and not in a comparison between
  two of its own configurations.

  The generator carries its own linear congruential sequence rather than using
  `rand`, because a failing case has to be reachable again from its seed.  It is
  threaded like everything else: a roll answers with the generator that comes
  after it."
  (:require [clojure.string :as str]
            [wolv.i64 :as i64]))

(def SIZE 16)
(def VARS ["v0" "v1" "v2" "v3"])
(def CONSTANTS [0 1 2 3 7 8 15 16 100 4095 4096 65536 -1 -8 1099511627776])
(def ARGUMENTS [[0 0 0] [1 2 3] [-1 7 -13] [Long/MAX_VALUE Long/MIN_VALUE 2]])
(def ORDERS ["=" "<>" "<" "<=" ">" ">="])

;; -- the source of chance ----------------------------------------------------

(defn seeded [seed] seed)

(defn- next-state [g]
  (unchecked-add (unchecked-multiply 6364136223846793005 g) 1442695040888963407))

(defn below [g n]
  (let [g (next-state g)]
    [g (mod (unsigned-bit-shift-right g 33) n)]))

(defn roll [g]
  (let [[g n] (below g 1000)] [g (/ n 1000.0)]))

(defn pick [g xs]
  (let [[g n] (below g (count xs))] [g (nth xs n)]))

(defn between [g lo hi]
  (let [[g n] (below g (inc (- hi lo)))] [g (+ lo n)]))

(defn weighted
  "`+` twice as likely as `/`, because a division that turns out to be by zero
  throws the whole expression away and generating them is not free."
  [g choices weights]
  (let [[g target] (below g (reduce + weights))]
    [g (loop [choices choices weights weights seen 0]
         (if (< target (+ seen (first weights)))
           (first choices)
           (recur (rest choices) (rest weights) (+ seen (first weights)))))]))

;; -- the arithmetic half -----------------------------------------------------

(defn literal [value]
  ;; `(- Long/MIN_VALUE)` overflows, and the literal the language wants for it
  ;; is `~9223372036854775808`, so the negation is the promoting one.
  (if (neg? value) (str "~" (-' value)) (str value)))

(defn expression [g depth]
  (let [[g r] (roll g)]
    (cond
      (or (zero? depth) (< r 0.25))
      (let [[g r2] (roll g)]
        (if (< r2 0.5)
          (let [[g v] (pick g ["a" "b" "c"])] [g [:var v]])
          (let [[g v] (pick g CONSTANTS)] [g [:int v]])))

      :else
      (let [[g r2] (roll g)]
        (if (< r2 0.1)
          (let [[g op] (pick g ORDERS)
                [g a] (expression g (dec depth))
                [g b] (expression g (dec depth))
                [g c] (expression g (dec depth))
                [g d] (expression g (dec depth))]
            [g [:if op a b c d]])
          (let [[g op] (weighted g ["+" "-" "*" "/" "mod"] [4 3 3 1 1])
                [g a] (expression g (dec depth))
                [g b] (expression g (dec depth))]
            [g [:bin op a b]]))))))

(defn compares [op a b]
  (case op "=" (= a b) "<>" (not= a b) "<" (< a b) "<=" (<= a b) ">" (> a b) (>= a b)))

(defn evaluate
  "Thrown at when a generated expression turns out to divide by zero; the caller
  throws that expression away and rolls another."
  [node env]
  (case (first node)
    :var (get env (second node))
    :int (second node)
    :if (let [[_ op a b then els] node]
          (evaluate (if (compares op (evaluate a env) (evaluate b env)) then els) env))
    (let [[_ op x y] node
          a (evaluate x env)
          b (evaluate y env)]
      (case op
        "+" (i64/i64+ a b)
        "-" (i64/i64- a b)
        "*" (i64/i64* a b)
        (if (zero? b)
          (throw (ex-info "divided by zero" {:oracle true}))
          (if (= op "/") (i64/i64-quot a b) (i64/i64-rem a b)))))))

(defn show [node]
  (case (first node)
    :var (second node)
    :int (literal (second node))
    :if (let [[_ op a b then els] node]
          (str "(if " (show a) " " op " " (show b) " then " (show then)
               " else " (show els) ")"))
    (let [[_ op a b] node] (str "(" (show a) " " op " " (show b) ")"))))

(defn arithmetic
  "`n` functions of three arguments, and what they print."
  [seed n]
  (loop [g (seeded seed) made 0 definitions [] calls [] expected []]
    (if (= made n)
      [(str (str/join "\n" (concat definitions calls)) "\n")
       (str (str/join "\n" expected) "\n")]
      (let [[g depth] (between g 1 5)
            [g tree] (expression g depth)
            values (try (mapv (fn [args] (evaluate tree (zipmap ["a" "b" "c"] args)))
                              ARGUMENTS)
                        (catch clojure.lang.ExceptionInfo _ nil))]
        (if-not values
          (recur g made definitions calls expected)
          (recur g (inc made)
                 (conj definitions
                       (str "fun f" made " (a : int, b : int, c : int) : int = " (show tree)))
                 (into calls
                       (map (fn [args]
                              (str "val () = (printInt (f" made " ("
                                   (str/join ", " (map literal args)) ")); print (\"\\n\"))"))
                            ARGUMENTS))
                 (into expected (map str values))))))))

;; -- the imperative half -----------------------------------------------------

(declare place)

(defn statement [g depth scope fresh]
  (let [[g r] (roll g)]
    (cond
      (and (pos? depth) (< r 0.2))
      (let [[g op] (pick g ORDERS)
            [g a] (place g scope)
            [g b] (place g scope)
            [g fresh then] (statement g (dec depth) scope fresh)
            [g fresh els] (statement g (dec depth) scope fresh)]
        [g fresh [:if op a b then els]])

      (and (pos? depth) (< r 0.45))
      (let [fresh (inc fresh)
            name (str "i" fresh)
            [g lo] (between g 0 2)
            [g hi] (between g 2 5)
            [g fresh body] (statement g (dec depth) (conj scope name) fresh)]
        [g fresh [:for name lo hi body]])

      (and (pos? depth) (< r 0.55))
      (let [[g fresh a] (statement g (dec depth) scope fresh)
            [g fresh b] (statement g (dec depth) scope fresh)]
        [g fresh [:seq [a b]]])

      (< r 0.8)
      (let [[g name] (pick g VARS)
            [g e] (place g scope)]
        [g fresh [:set name e]])

      :else
      (let [[g a] (place g scope)
            [g b] (place g scope)]
        [g fresh [:put a b]]))))

(defn place
  "An expression over the variables in scope and the array."
  [g scope]
  (let [[g r] (roll g)]
    (cond
      (< r 0.35) (let [[g v] (pick g scope)] [g [:var v]])
      (< r 0.5) (let [[g v] (pick g CONSTANTS)] [g [:int v]])
      (< r 0.65) (let [[g e] (place g scope)] [g [:get e]])
      :else (let [[g op] (pick g ["+" "-" "*"])
                  [g a] (place g scope)
                  [g b] (place g scope)]
              [g [:bin op a b]]))))

(defn cell
  "`index` in the generated program: the remainder, made positive."
  [value]
  (mod (+ (i64/i64- value (i64/i64* (i64/i64-quot value SIZE) SIZE)) SIZE) SIZE))

(defn run-place [node env array]
  (case (first node)
    :var (get env (second node))
    :int (second node)
    :get (nth array (cell (run-place (second node) env array)))
    (let [[_ op x y] node
          a (run-place x env array)
          b (run-place y env array)]
      (case op "+" (i64/i64+ a b) "-" (i64/i64- a b) (i64/i64* a b)))))

(defn run-statement
  "The environment is threaded rather than mutated, because a `for` binds a
  variable that the loop above it does not have — and so is the array, because
  nothing here is mutated."
  [node env array]
  (case (first node)
    :set [(assoc env (second node) (run-place (nth node 2) env array)) array]
    :put [env (assoc array (cell (run-place (second node) env array))
                     (run-place (nth node 2) env array))]
    :seq (reduce (fn [[env array] item] (run-statement item env array))
                 [env array] (second node))
    :if (let [[_ op x y then els] node
              a (run-place x env array)
              b (run-place y env array)]
          (run-statement (if (compares op a b) then els) env array))
    (let [[_ name lo hi body] node]
      (reduce (fn [[env array] i] (run-statement body (assoc env name i) array))
              [env array] (range lo (inc hi))))))

(defn show-place [node]
  (case (first node)
    :get (str "xs[index (" (show-place (second node)) ")]")
    :bin (let [[_ op a b] node]
           (str "(" (show-place a) " " op " " (show-place b) ")"))
    (show node)))

(defn show-statement [node indent]
  (case (first node)
    :set (str indent (second node) " := " (show-place (nth node 2)))
    :put (str indent "xs[index (" (show-place (second node)) ")] := "
              (show-place (nth node 2)))
    :seq (str indent "(\n"
              (str/join ";\n" (map #(show-statement % (str indent "  ")) (second node)))
              "\n" indent ")")
    :if (let [[_ op a b then els] node]
          (str indent "if " (show-place a) " " op " " (show-place b) " then\n"
               (show-statement then (str indent "  ")) "\n"
               indent "else\n" (show-statement els (str indent "  "))))
    (let [[_ name lo hi body] node]
      (str indent "for " name " = " lo " to " hi " do\n"
           (show-statement body (str indent "  "))))))

(def PREAMBLE
  (str "val xs = array (16, 0)\n"
       "fun index (n : int) : int =\n"
       "  let val r = n - n / 16 * 16 in\n"
       "    if r < 0 then r + 16 else r\n"
       "  end\n"))

(defn imperative
  "A program of assignments, loops and branches over an array."
  [seed n]
  (let [[_ body] (reduce (fn [[g done] _]
                           (let [[g _ s] (statement g 3 VARS 0)] [g (conj done s)]))
                         [(seeded seed) []] (range n))
        [env array] (reduce (fn [[env array] item] (run-statement item env array))
                            [(zipmap VARS (repeat 0)) (vec (repeat SIZE 0))]
                            body)
        expected (concat (map #(str (get env %)) VARS) (map str array))
        out (concat [PREAMBLE]
                    (map #(str "var " % " = 0") VARS)
                    ["val () = ("
                     (str/join ";\n" (map #(show-statement % "  ") body))
                     ")"]
                    (map #(str "val () = (printInt (" % "); print (\"\\n\"))") VARS)
                    ["val () = for k = 0 to 15 do (printInt (xs[k]); print (\"\\n\"))"])]
    [(str (str/join "\n" out) "\n")
     (str (str/join "\n" expected) "\n")]))

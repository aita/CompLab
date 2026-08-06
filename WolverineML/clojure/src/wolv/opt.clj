(ns wolv.opt
  "Optimisation on SSA.

  Five small passes run to a fixed point.  Each is cheap because SSA makes it
  cheap: a register has one definition, so constant folding and copy propagation
  are a lookup rather than a dataflow problem, and a phi whose arguments all
  agree is a copy that was never needed.

      fold constants   ->  arithmetic on known values
      propagate copies ->  `:move`, and phis that turned into one
      simplify phis    ->  a phi with one distinct argument is that argument
      fold branches    ->  a branch on a known value, and the blocks it strands
      dead code        ->  anything computed and not used

  A pass here answers with a function rather than with a flag, so a round is
  `=` on what came out and nothing has to report whether it did anything."
  (:require [wolv.i64 :as i64]
            [wolv.ir :as ir]))

;; -- rewriting ---------------------------------------------------------------

(defn- rewrite
  "Replace registers everywhere they are read, phi arguments included.  A chain
  of copies is followed to its end, and the `seen` guard is what stops a phi
  that was simplified into itself from spinning."
  [f mapping]
  (if (empty? mapping)
    f
    (let [resolve* (fn [r]
                     (loop [r r seen #{}]
                       (if (and (contains? mapping r) (not (contains? seen r)))
                         (recur (get mapping r) (conj seen r))
                         r)))]
      (ir/map-blocks
       f
       (fn [b]
         (-> b
             (update :phis (fn [ps]
                             (mapv (fn [p]
                                     (update p :args
                                             #(mapv (fn [[pred r]] [pred (resolve* r)]) %)))
                                   ps)))
             (update :instrs (fn [is] (mapv #(ir/map-uses % resolve*) is)))))))))

(defn- constants [f]
  (into {} (for [b (ir/blocks f)
                 i (ir/instrs b)
                 :when (= (:op i) :const)]
             [(:dst i) (:value i)])))

;; -- folding -----------------------------------------------------------------

(defn- arith
  "The arithmetic of the machine, done here rather than in the host's width."
  [op a b]
  (case op
    "+" (i64/i64+ a b)
    "-" (i64/i64- a b)
    "*" (i64/i64* a b)
    "/" (when-not (zero? b) (i64/i64-quot a b))
    "mod" (when-not (zero? b) (i64/i64-rem a b))
    "and" (i64/i64-and a b)
    "or" (i64/i64-or a b)
    "xor" (i64/i64-xor a b)
    "shl" (i64/i64-shl a b)
    "shr" (i64/i64-shr a b)
    nil))

(defn- order [op a b]
  (case op
    "=" (= a b)
    "<>" (not= a b)
    "<" (< a b)
    "<=" (<= a b)
    ">" (> a b)
    ">=" (>= a b)
    "u<" (< (i64/unsigned a) (i64/unsigned b))
    "u>=" (>= (i64/unsigned a) (i64/unsigned b))
    (throw (ex-info (str "unknown comparison " op) {}))))

(defmulti ^:private fold-one
  "What this instruction becomes when what it reads is known, or nil."
  (fn [i _known] (:op i)))

(defmethod fold-one :default [_ _] nil)

(defmethod fold-one :bin [i known]
  (let [{:keys [dst oper lhs rhs]} i
        a (get known lhs)
        b (get known rhs)]
    (cond
      (and a b) (when-let [value (arith oper a b)] (ir/i-const dst value))
      ;; The identities are worth having on their own: `x shl 0` and `x * 1`
      ;; come out of lowering an index, and folding them is what lets the
      ;; selector see one `add` where there were three instructions.
      (and (= b 0) (contains? #{"+" "-" "or" "xor" "shl" "shr"} oper)) (ir/i-move dst lhs)
      (and (= b 1) (contains? #{"*" "/"} oper)) (ir/i-move dst lhs)
      (and (= a 0) (= oper "+")) (ir/i-move dst rhs)
      :else nil)))

(defmethod fold-one :cmp [i known]
  (let [a (get known (:lhs i))
        b (get known (:rhs i))]
    (when (and a b)
      (ir/i-const (:dst i) (if (order (:oper i) a b) 1 0)))))

;; -- the passes --------------------------------------------------------------

(defn- fold-constants [f]
  (let [[f _]
        (reduce
         (fn [[f known] label]
           (let [[is known]
                 (reduce (fn [[done known] i]
                           (if-let [folded (fold-one i known)]
                             [(conj done folded)
                              (if (= (:op folded) :const)
                                (assoc known (:dst folded) (:value folded))
                                known)]
                             [(conj done i) known]))
                         [[] known] (ir/instrs (ir/block-of f label)))]
             [(ir/set-instrs f label is) known]))
         [f (constants f)] (:order f))]
    f))

(defn- propagate-copies [f]
  (let [mapping (into {} (for [b (ir/blocks f)
                               i (ir/instrs b)
                               :when (= (:op i) :move)]
                           [(:dst i) (:src i)]))]
    (if (empty? mapping)
      f
      (ir/map-blocks (rewrite f mapping)
                     (fn [b] (update b :instrs #(filterv (fn [i] (not= (:op i) :move)) %)))))))

(defn- simplify-phis [f]
  (let [mapping (into {} (for [b (ir/blocks f)
                               p (:phis b)
                               :let [others (distinct (remove #(= % (:dst p))
                                                              (map second (:args p))))]
                               :when (= 1 (count others))]
                           [(:dst p) (first others)]))]
    (if (empty? mapping)
      f
      (rewrite (ir/map-blocks f (fn [b]
                                  (update b :phis
                                          #(filterv (fn [p] (not (contains? mapping (:dst p))))
                                                    %))))
               mapping))))

(defn- fold-branches [f]
  (let [known (constants f)
        folded (reduce
                (fn [f label]
                  (let [b (ir/block-of f label)
                        t (ir/terminator b)]
                    (if (not= (:op t) :cbr)
                      f
                      (let [value (get known (:test t))]
                        (if (or value (= (:then t) (:else t)))
                          (let [taken (if (or (nil? value) (not (zero? value)))
                                        (:then t) (:else t))]
                            (ir/set-instrs f label
                                           (conj (vec (butlast (ir/instrs b)))
                                                 (ir/i-jmp taken))))
                          f)))))
                f (:order f))]
    (if (= folded f) f (ir/drop-unreachable folded))))

(defn- dead-code
  "Removing one dead value can make another dead, so this one has a fixed point
  of its own rather than waiting for the next round."
  [f]
  (let [used (into #{} (concat (for [b (ir/blocks f) p (:phis b) [_ r] (:args p)] r)
                               (for [b (ir/blocks f) i (ir/instrs b) r (ir/uses i)] r)))
        next (ir/map-blocks
              f
              (fn [b]
                (-> b
                    (update :phis #(filterv (fn [p] (contains? used (:dst p))) %))
                    (update :instrs
                            #(filterv (fn [i]
                                        (let [d (ir/defs i)]
                                          (not (and d (not (contains? used d))
                                                    (not (ir/effect? i))))))
                                      %)))))]
    (if (= next f) f (recur next))))

(def ^:private passes [fold-constants propagate-copies simplify-phis fold-branches dead-code])

(defn optimise-func [f]
  ;; Every pass runs every round: they are cheap, and one enables another.
  (loop [f f]
    (let [next (reduce (fn [f pass] (pass f)) f passes)]
      (if (= next f) f (recur next)))))

(defn optimise [m] (update m :funcs #(mapv optimise-func %)))

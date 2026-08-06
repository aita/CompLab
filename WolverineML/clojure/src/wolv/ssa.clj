(ns wolv.ssa
  "SSA construction, the textbook way.

  Dominators by the iterative algorithm of Cooper, Harvey and Kennedy, dominance
  frontiers from those, phis at the frontiers of every definition, and then one
  walk of the dominator tree renaming as it goes.  This is minimal SSA and
  nothing cleverer: a phi is placed wherever the frontier says, whether or not
  the variable is live there, and the dead ones leave in `opt.clj`.

  Only registers written more than once take part.  Everything lowering produced
  once — a temporary — is already in SSA and is left with the name it has.

  Blocks are named, so every set of them is walked in name order, which is what
  keeps two runs — and two implementations — placing phis identically."
  (:require [clojure.set :as set]
            [wolv.ir :as ir]))

(defn sorted-labels [s] (sort s))

;; -- dominance ---------------------------------------------------------------

(defn dominates? [dom a b]
  (loop [b b]
    (if (= a b)
      true
      (let [parent (get (:idom dom) b)]
        (if (= parent b) false (recur parent))))))

(defn- intersect
  "The two runners climb until they meet, each time from the deeper one."
  [idom rank a b]
  (loop [a a b b]
    (if (= a b)
      a
      (let [a (loop [a a] (if (> (rank a) (rank b)) (recur (idom a)) a))
            b (loop [b b] (if (> (rank b) (rank a)) (recur (idom b)) b))]
        (recur a b)))))

(defn- settle-idom [f order rank]
  (loop [idom {(:entry f) (:entry f)}]
    (let [next (reduce (fn [idom label]
                         (let [preds (filter #(contains? idom %)
                                             (:preds (ir/block-of f label)))]
                           (if (empty? preds)
                             idom
                             (let [new (reduce (fn [acc p] (intersect idom rank p acc))
                                               (first preds) (rest preds))]
                               (assoc idom label new)))))
                       idom (rest order))]
      (if (= next idom) idom (recur next)))))

(defn- frontiers-of [f idom order]
  (reduce
   (fn [frontier label]
     (let [b (ir/block-of f label)]
       (if (< (count (:preds b)) 2)
         frontier
         (reduce (fn [frontier pred]
                   (loop [frontier frontier runner pred]
                     (if (and (not= runner (get idom label)) (contains? idom runner))
                       (recur (update frontier runner (fnil conj #{}) label)
                              (get idom runner))
                       frontier)))
                 frontier (:preds b)))))
   (zipmap order (repeat #{}))
   order))

(defn dominance-of [f]
  (let [order (ir/rpo f)
        rank (zipmap order (range))
        idom (settle-idom f order rank)
        children (reduce (fn [children label]
                           (let [parent (get idom label)]
                             (if (= parent label)
                               children
                               (update children parent conj label))))
                         (zipmap order (repeat []))
                         order)]
    {:idom idom :children children :frontier (frontiers-of f idom order) :order order}))

;; -- where each register is written ------------------------------------------

;; A register written twice in one block is as much a variable as one written in
;; two blocks, so the count is what decides, and the blocks are what the
;; frontier walk needs.
(defn definitions [f]
  (let [note (fn [d r label]
               (-> d
                   (update-in [:blocks r] (fnil conj #{}) label)
                   (update-in [:count r] (fnil inc 0))))
        d (reduce (fn [d b]
                    (reduce (fn [d i]
                              (if-let [r (ir/defs i)] (note d r (:label b)) d))
                            d (ir/instrs b)))
                  {:blocks {} :count {}} (ir/blocks f))]
    (reduce (fn [d p] (note d p (:entry f))) d (:params f))))

(defn variables [d]
  (sort (keep (fn [[r n]] (when (> n 1) r)) (:count d))))

;; -- placing -----------------------------------------------------------------

;; A phi for `v` at every dominance frontier of a block defining `v`.  What each
;; block's phis are for is kept beside them: the renamer needs the variable, and
;; the phi itself only remembers what it was renamed to.
(defn- place-one [f phi-vars dom sites v]
  (loop [f f phi-vars phi-vars placed #{} work (vec (sorted-labels (get sites v)))]
    (if (empty? work)
      [f phi-vars]
      (let [b (peek work)
            rest-work (pop work)
            [f phi-vars placed added]
            (reduce (fn [[f pv placed added] target]
                      (if (contains? placed target)
                        [f pv placed added]
                        (let [block (ir/block-of f target)
                              made (ir/phi v (mapv (fn [p] [p v]) (:preds block)))]
                          [(ir/set-phis f target (conj (:phis block) made))
                           (update pv target conj v)
                           (conj placed target)
                           (conj added target)])))
                    [f phi-vars placed []]
                    (sorted-labels (get (:frontier dom) b)))]
        (recur f phi-vars placed
               (into rest-work (remove #(contains? (get sites v) %) added)))))))

(defn place-phis [f dom d]
  (reduce (fn [[f phi-vars] v] (place-one f phi-vars dom (:blocks d) v))
          [f (zipmap (:order f) (repeat []))]
          (variables d)))

;; -- renaming ----------------------------------------------------------------

;; `:stacks` is the reaching definition of each variable, `:undefined` the
;; register a variable read on a path that never wrote it reads from.
(defn- variable? [re v] (contains? (:vars re) v))

(defn- undef
  "A variable read before it was ever written reads zero."
  [re v]
  (if-let [found (get (:undefined re) v)]
    [re found]
    (let [[f r] (ir/new-reg (:f re))]
      [(-> re (assoc :f f) (assoc-in [:undefined v] r) (update :undef-order conj v)) r])))

(defn- top [re v]
  (if-let [stack (seq (get (:stacks re) v))]
    [re (first stack)]
    (undef re v)))

(defn- rename-name [re v]
  (let [[f fresh] (ir/new-reg (:f re))]
    [(-> re (assoc :f f) (update-in [:stacks v] conj fresh)) fresh]))

(defn- pop-name [re v] (update-in re [:stacks v] rest))

(defn- plant-undefined
  "The zeros go in front of the entry block, in the order they were made."
  [re]
  (let [entry (:entry (:f re))
        is (reduce (fn [is v] (cons (ir/i-const (get (:undefined re) v) 0) is))
                   (ir/instrs (ir/block-of (:f re) entry))
                   (:undef-order re))]
    (ir/set-instrs (:f re) entry is)))

(defn- rename-uses
  "The reaching definition of every variable this instruction reads.  `uses`
  gives them in the order they are numbered in, which is why the map is built
  by walking it."
  [re i]
  (reduce (fn [[re m] r]
            (if (or (contains? m r) (not (variable? re r)))
              [re m]
              (let [[re r'] (top re r)] [re (assoc m r r')])))
          [re {}] (ir/uses i)))

(defn- rename-block [re label]
  (let [block (ir/block-of (:f re) label)
        vars (get (:phi-vars re) label)
        [re phis mine]
        (reduce (fn [[re phis mine] [p v]]
                  (let [[re fresh] (rename-name re v)]
                    [re (conj phis (ir/phi fresh (:args p))) (conj mine v)]))
                [re [] []] (map vector (:phis block) vars))
        re (assoc re :f (ir/set-phis (:f re) label phis))
        [re instrs mine]
        (reduce (fn [[re done mine] i]
                  (let [[re mapping] (rename-uses re i)
                        renamed (ir/map-uses i (fn [r] (get mapping r r)))
                        d (ir/defs renamed)]
                    (if (and d (variable? re d))
                      (let [[re fresh] (rename-name re d)]
                        [re (conj done (ir/with-def renamed fresh)) (conj mine d)])
                      [re (conj done renamed) mine])))
                [re [] mine] (ir/instrs block))
        re (assoc re :f (ir/set-instrs (:f re) label instrs))
        re (reduce
            (fn [re succ]
              (let [target (ir/block-of (:f re) succ)
                    theirs (get (:phi-vars re) succ)
                    [re phis] (reduce (fn [[re phis] [p v]]
                                        (let [[re r] (top re v)]
                                          [re (conj phis (ir/phi-set-arg label r p))]))
                                      [re []] (map vector (:phis target) theirs))]
                (assoc re :f (ir/set-phis (:f re) succ phis))))
            re (ir/succs (ir/block-of (:f re) label)))]
    [re mine]))

(defn- run-renamer
  "The dominator tree, walked with an explicit stack so that what a block pushed
  comes off again when its subtree is done."
  [re]
  (loop [re re pushed {} work (list [(:entry (:f re)) false])]
    (if (empty? work)
      re
      (let [[label done?] (first work)
            rest-work (rest work)]
        (if done?
          (recur (reduce pop-name re (get pushed label)) pushed rest-work)
          (let [[re mine] (rename-block re label)]
            (recur re (assoc pushed label mine)
                   (concat (map (fn [c] [c false])
                                (get (:children (:dom re)) label))
                           [[label true]]
                           rest-work))))))))

;; -- the passes --------------------------------------------------------------

(defn construct [f]
  (let [f (ir/recompute-preds f)
        dom (dominance-of f)
        d (definitions f)
        [f phi-vars] (place-phis f dom d)
        re {:f f :dom dom :phi-vars phi-vars :vars (set (variables d))
            :stacks {} :undefined {} :undef-order []}
        [re params] (reduce (fn [[re ps] p]
                              (if (variable? re p)
                                (let [[re p'] (rename-name re p)] [re (conj ps p')])
                                [re (conj ps p)]))
                            [re []] (:params (:f re)))
        re (assoc re :f (assoc (:f re) :params params))
        re (run-renamer re)]
    (plant-undefined re)))

(defn construct-module [m] (update m :funcs #(mapv construct %)))

(defn split-critical-edges
  "Give every phi a place to put its copy in.

  An edge from a block with several successors into a block with several
  predecessors has nowhere to hold the copies a phi turns into, so it gets a
  block of its own.  The same goes for any edge into a block that still has a
  phi, so that the emitter only ever has to put copies before a `jmp`."
  [f]
  (ir/recompute-preds
   (reduce
    (fn [f label]
      (let [b (ir/block-of f label)]
        (if (< (count (ir/succs b)) 2)
          f
          (reduce
           (fn [f succ]
             (let [b (ir/block-of f label)
                   target (ir/block-of f succ)]
               (if (and (< (count (:preds target)) 2) (empty? (:phis target)))
                 f
                 (let [split-label (str label "." succ)
                       f (-> f
                             (ir/add-block split-label)
                             (ir/emit split-label (ir/i-jmp succ)))
                       is (ir/instrs (ir/block-of f label))
                       f (ir/set-instrs f label
                                        (conj (vec (butlast is))
                                              (ir/rename-target (last is) succ split-label)))]
                   (ir/set-phis f succ
                                (mapv (fn [p]
                                        (if-let [[r p'] (ir/phi-remove-arg label p)]
                                          (ir/phi-set-arg split-label r p')
                                          p))
                                      (:phis (ir/block-of f succ))))))))
           f (ir/succs b)))))
    f (:order f))))

;; -- what SSA promises -------------------------------------------------------

(defn verify [f]
  (let [dom (dominance-of f)
        define (fn [defn* r where]
                 (when (contains? defn* r)
                   (throw (ex-info (str "%" r " is defined twice") {})))
                 (assoc defn* r where))
        definition (reduce
                    (fn [acc b]
                      (let [acc (reduce (fn [acc p] (define acc (:dst p) (:label b)))
                                        acc (:phis b))]
                        (reduce (fn [acc i]
                                  (if-let [d (ir/defs i)] (define acc d (:label b)) acc))
                                acc (ir/instrs b))))
                    {} (ir/blocks f))
        definition (reduce (fn [acc p]
                             (if (contains? acc p) acc (assoc acc p (:entry f))))
                           definition (:params f))
        reaches (fn [r where what]
                  (let [at (get definition r)]
                    (when-not at
                      (throw (ex-info (str "%" r " is never defined") {})))
                    (when-not (dominates? dom at where)
                      (throw (ex-info (str "%" r " does not reach " what) {})))))]
    (doseq [b (ir/blocks f)]
      (doseq [p (:phis b)]
        (when-not (= (sort (ir/phi-preds p)) (sort (:preds b)))
          (throw (ex-info (str "the phi in " (:label b) " does not name its predecessors")
                          {})))
        (doseq [[pred r] (:args p)]
          (reaches r pred (str (:label b) " through " pred))))
      (doseq [i (ir/instrs b) r (ir/uses i)]
        (reaches r (:label b) (str "its use in " (:label b)))))
    f))

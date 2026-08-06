(ns wolv.spill
  "Spilling.

  A spilled value gets a frame slot, a store after every definition of it and a
  reload in front of every use.  The reloads are new registers, live from the
  load to the instruction under it and nowhere else, which is what makes the
  pressure come down.  Nothing here assumes SSA: a value written twice gets two
  stores, and a phi argument is reloaded at the end of the predecessor it comes
  from, so the same rewrite serves the graph before and after it left SSA."
  (:require [wolv.ir :as ir]
            [wolv.ssa :as ssa]))

(defn out-of-registers
  "Thrown when spilling cannot help either."
  [message]
  (throw (ex-info message {:wolv :out-of-registers})))

(defn loop-depth
  "How deeply each block is nested in loops, for weighing what a use costs.

  A back edge is an edge into a block that dominates its source; everything that
  can reach the source without leaving the dominated region is in that loop."
  [f]
  (let [dom (ssa/dominance-of f)]
    (reduce
     (fn [depth [label succ]]
       (if-not (ssa/dominates? dom succ label)
         depth
         (let [body (loop [body #{succ} stack [label]]
                      (if-let [at (first stack)]
                        (if (contains? body at)
                          (recur body (rest stack))
                          (recur (conj body at)
                                 (into (vec (rest stack))
                                       (reverse (:preds (ir/block-of f at))))))
                        body))]
           (reduce (fn [depth label] (update depth label (fnil inc 0))) depth body))))
     (zipmap (:order f) (repeat 0))
     (for [b (ir/blocks f) s (ir/succs b)] [(:label b) s]))))

(defn costs
  "What spilling a value would cost: its reads and writes, weighed by loops."
  [f]
  (let [depth (loop-depth f)
        scale (fn [label] (double (long (Math/pow 10 (min (get depth label) 4)))))]
    (reduce
     (fn [weight b]
       (let [here (scale (:label b))
             weight (reduce (fn [weight p]
                              (-> (reduce (fn [weight [pred r]]
                                            (update weight r (fnil + 0.0) (scale pred)))
                                          weight (:args p))
                                  (update (:dst p) (fnil + 0.0) here)))
                            weight (:phis b))]
         (reduce (fn [weight i]
                   (let [weight (reduce (fn [weight r] (update weight r (fnil + 0.0) here))
                                        weight (ir/uses i))]
                     (if-let [d (ir/defs i)] (update weight d (fnil + 0.0) here) weight)))
                 weight (ir/instrs b))))
     {} (ir/blocks f))))

(defn- rewrite-block
  "Reload in front of every use, and store after every definition."
  [f label victim slot reloads]
  (reduce
   (fn [[f is reloads] i]
     ;; The store this pass just put in reads the victim on purpose.
     (let [store? (and (= (:op i) :store-slot) (= (:slot i) slot))
           reads? (and (not store?) (some #{victim} (ir/uses i)))]
       (if reads?
         (let [[f fresh] (ir/new-reg f)
               rewritten (ir/map-uses i #(if (= % victim) fresh %))]
           [f (cond-> (conj is (ir/i-load-slot fresh slot) rewritten)
                (= (ir/defs i) victim) (conj (ir/i-store-slot slot victim)))
            (conj reloads fresh)])
         [f (cond-> (conj is i)
              (= (ir/defs i) victim) (conj (ir/i-store-slot slot victim)))
          reloads])))
   [f [] reloads] (ir/instrs (ir/block-of f label))))

(defn- reload-phi-args
  "A phi argument is reloaded at the end of the predecessor it comes from."
  [f label victim slot reloads]
  (reduce
   (fn [[f phis reloads] p]
     (let [[f p reloads]
           (reduce (fn [[f p reloads] [pred r]]
                     (if (not= r victim)
                       [f p reloads]
                       (let [[f fresh] (ir/new-reg f)
                             is (ir/instrs (ir/block-of f pred))
                             f (ir/set-instrs f pred
                                              (concat (butlast is)
                                                      [(ir/i-load-slot fresh slot)]
                                                      [(last is)]))]
                         [f (ir/phi-set-arg pred fresh p) (conj reloads fresh)])))
                   [f p reloads] (:args p))]
       [f (conj phis p) reloads]))
   [f [] reloads] (:phis (ir/block-of f label))))

(defn spill
  "Give `victim` a frame slot, and answer with the function, where it went, and
  the reloads that replaced it."
  [f victim slots]
  (let [[f slot] (ir/new-slot f)
        slots (assoc slots victim slot)
        param? (boolean (some #{victim} (:params f)))
        order (:order f)
        [f reloads]
        (reduce
         (fn [[f reloads] label]
           (let [b (ir/block-of f label)
                 stores (concat (when (some #(= (:dst %) victim) (:phis b))
                                  [(ir/i-store-slot slot victim)])
                                (when (and param? (= label (:entry f)))
                                  [(ir/i-store-slot slot victim)]))
                 f (ir/set-instrs f label (concat stores (ir/instrs b)))
                 [f is reloads] (rewrite-block f label victim slot reloads)]
             [(ir/set-instrs f label is) reloads]))
         [f #{}] order)
        [f reloads]
        (reduce (fn [[f reloads] label]
                  (let [[f phis reloads] (reload-phi-args f label victim slot reloads)]
                    [(ir/set-phis f label phis) reloads]))
                [f reloads] order)]
    [f slots reloads]))

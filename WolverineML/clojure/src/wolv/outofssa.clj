(ns wolv.outofssa
  "Leaving SSA before allocation.

  A phi is a copy that happens on an edge, so it becomes copies at the end of
  each predecessor.  Critical edges are already split, so a predecessor of a
  block with phis has nowhere else to go and the copies can simply be appended.

  The copies of one edge happen at once: every argument is read before any
  destination is written.  Usually that needs no care, because a phi's
  destination is defined nowhere else and so is nobody's argument — but a block
  that is its own predecessor can have two phis that swap, and then the copies
  go through temporaries, which is Sreedhar's answer and which coalescing is
  expected to remove again."
  (:require [wolv.ir :as ir]))

(defn- copy-in-parallel [f label moves]
  (let [real (filterv (fn [[dst src]] (not= dst src)) moves)]
    (if (empty? real)
      f
      (let [written (into #{} (map first real))
            [f copies]
            (if (some written (map second real))
              ;; Something read is also written, so the two halves cannot be one
              ;; list.
              (let [[f through] (reduce (fn [[f m] [dst _]]
                                          (let [[f r] (ir/new-reg f)]
                                            [f (assoc m dst r)]))
                                        [f {}] real)]
                [f (concat (map (fn [[dst src]] (ir/i-move (through dst) src)) real)
                           (map (fn [[dst _]] (ir/i-move dst (through dst))) real))])
              [f (map (fn [[dst src]] (ir/i-move dst src)) real)])
            is (ir/instrs (ir/block-of f label))]
        (ir/set-instrs f label (concat (butlast is) copies [(last is)]))))))

(defn destruct
  "Replace every phi in `f` with copies in its predecessors."
  [f]
  (ir/recompute-preds
   (reduce
    (fn [f label]
      (let [b (ir/block-of f label)]
        (if (empty? (:phis b))
          f
          (let [f (reduce (fn [f pred]
                            (when-not (= 1 (count (ir/succs (ir/block-of f pred))))
                              (throw (ex-info (str pred " -> " label " is a critical edge") {})))
                            (copy-in-parallel f pred
                                              (mapv (fn [p]
                                                      [(:dst p) (second (ir/phi-arg p pred))])
                                                    (:phis b))))
                          f (:preds b))]
            (ir/set-phis f label [])))))
    f (:order f))))

(defn destruct-module [m] (update m :funcs #(mapv destruct %)))

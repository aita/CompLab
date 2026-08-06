(ns wolv.liveness
  "Liveness on SSA.

  The only subtlety is the phi.  A phi does not read its arguments where it
  stands; it reads them on the edges, so an argument is live at the end of the
  predecessor it is paired with and not anywhere inside the block that holds the
  phi.  Getting that wrong is what makes phi-related values interfere when they
  should not.

  A set of registers is a `sorted-set`, so walking one is already in the order
  that keeps a colouring the same twice, and `=` on two of them is set equality,
  which the fixed point below tests for."
  (:require [wolv.ir :as ir]))

(def empty-regs (sorted-set))

(defn regs [xs] (into empty-regs xs))
(defn union [a b] (into a b))
(defn without [a b] (reduce disj a b))

(defn live-in [l label] (get (:in l) label))
(defn live-out [l label] (get (:out l) label))

(defn- upward-and-killed
  "What a block reads before writing, and what it writes at all."
  [b]
  (loop [is (ir/instrs b)
         use empty-regs
         kill (regs (map :dst (:phis b)))]
    (if (empty? is)
      [use kill]
      (let [i (first is)
            use (reduce (fn [use r] (if (contains? kill r) use (conj use r)))
                        use (ir/uses i))
            d (ir/defs i)]
        (recur (rest is) use (if d (conj kill d) kill))))))

(defn analyse [f]
  (let [parts (into {} (map (fn [b] [(:label b) (upward-and-killed b)]) (ir/blocks f)))
        order (reverse (ir/rpo f))
        step (fn [l]
               (reduce
                (fn [l label]
                  (let [b (ir/block-of f label)
                        leaving (reduce
                                 (fn [acc succ]
                                   (reduce (fn [acc p]
                                             (if-let [a (ir/phi-arg p label)]
                                               (conj acc (second a))
                                               acc))
                                           (union acc (get (:in l) succ))
                                           (:phis (ir/block-of f succ))))
                                 empty-regs (ir/succs b))
                        [use kill] (get parts label)
                        entering (union use (without leaving kill))]
                    (-> l (assoc-in [:out label] leaving) (assoc-in [:in label] entering))))
                l order))]
    (loop [l {:in (zipmap (:order f) (repeat empty-regs))
              :out (zipmap (:order f) (repeat empty-regs))}]
      (let [next (step l)]
        (if (= next l) l (recur next))))))

(defn across-calls
  "Values that are live across a call, and so cannot sit in a scratch register."
  [f l]
  (reduce
   (fn [out b]
     (first
      (reduce (fn [[out after] i]
                (let [d (ir/defs i)
                      before (if d (disj after d) after)]
                  [(if (= (:op i) :call) (union out before) out)
                   (union before (regs (ir/uses i)))]))
              [out (live-out l (:label b))]
              (reverse (ir/instrs b)))))
   empty-regs (ir/blocks f)))

(defn pressure
  "The most values live at any one point — the registers the function wants."
  [f l]
  (reduce
   (fn [most b]
     (let [after0 (live-out l (:label b))
           worst (first
                  (reduce (fn [[most after] i]
                            (let [d (ir/defs i)
                                  next (union (if d (disj after d) after) (regs (ir/uses i)))]
                              [(max most (count next)) next]))
                          [(max most (count after0)) after0]
                          (reverse (ir/instrs b))))
           entering (reduce (fn [acc p] (conj acc (:dst p)))
                            (live-in l (:label b)) (:phis b))]
       (max worst (count entering))))
   0 (ir/blocks f)))

(ns wolv.graph
  "Register allocation by graph colouring, with iterated coalescing.

  The idea is Chaitin's: build a graph whose nodes are values and whose edges
  join values that are live at the same time, then colour it with as many
  colours as the machine has registers.  Colouring a graph is hard in general,
  but Kempe's observation makes it practical: a node with fewer than K
  neighbours can always be coloured whatever happens to the rest of the graph.
  So remove such nodes one at a time and push them on a stack; when the graph is
  empty, pop the stack and give each node a colour its neighbours have not
  taken.  If every remaining node has K or more neighbours, guess that one of
  them will not get a colour and carry on — if the guess was wrong the value is
  rewritten to live in memory and the whole thing runs again (Briggs' optimistic
  colouring).

  On top of that sits coalescing, which is why leaving SSA first costs nothing.
  Leaving SSA fills the predecessors of every join with copies; coalescing
  merges the two ends of a copy so that it disappears.  Merging aggressively can
  make a graph uncolourable, so a merge only happens when Briggs' test proves it
  cannot: the merged node must have fewer than K neighbours of significant
  degree.  That test is only exact enough to be useful if degrees are up to
  date, and simplifying lowers degrees while merging raises them — so the two
  run interleaved, with freezing (giving up on a copy so its nodes can be
  simplified) as the way out when neither applies.  Hence \"iterated\" (George
  and Appel, 1996).

  This machine has no fixed registers to colour against, so the calling
  convention is carried as a set of colours each node may not take: a value live
  across a call may not take a caller-saved one.  A node with `f` forbidden
  colours and `d` neighbours needs `d + f < K` to be trivially colourable, so
  that sum is what stands in for the degree everywhere below.

  Every worklist here is a `sorted-set`, because the order matters: which node
  is simplified first and which copy is looked at first decide the colouring, so
  `first` on one of these is \"the least\" and walking one is already in order.
  The whole colouring is a map that each step answers with a new one of."
  (:require [wolv.hints :as hints]
            [wolv.ir :as ir]
            [wolv.liveness :as live]
            [wolv.registers :as reg]
            [wolv.spill :as spill]))

(def ^:private none (sorted-set))

(defn- new-colouring [f machine protected]
  {:f f :machine machine :protected protected
   :adjacent {} :degree {} :forbidden {} :preferred {}
   :moves {} :nmoves 0 :moves-of {}
   :worklist-moves none :active-moves none
   :simplify none :freeze none :spill-wl none
   :select-stack () :on-stack #{} :coalesced none :alias {} :colour {}})

(defn- k [c] (reg/register-count (:machine c)))

;; -- the graph ---------------------------------------------------------------

(defn- node [c r]
  (if (contains? (:adjacent c) r)
    c
    (-> c
        (assoc-in [:adjacent r] none)
        (assoc-in [:degree r] 0)
        (assoc-in [:forbidden r] none))))

(defn- adjacent [c r] (get (:adjacent c) r))
(defn- forbidden [c r] (get (:forbidden c) r))
(defn- degree [c r] (get (:degree c) r))

(defn- add-edge [c a b]
  (if (or (= a b) (contains? (adjacent c a) b))
    c
    (-> c
        (update-in [:adjacent a] conj b)
        (update-in [:adjacent b] conj a)
        (update-in [:degree a] inc)
        (update-in [:degree b] inc))))

(defn- weight
  "The degree, counting a forbidden colour as a neighbour holding it."
  [c r]
  (+ (degree c r) (count (forbidden c r))))

(defn- add-move [c dst src]
  (let [index (:nmoves c)]
    [(-> c
         (assoc-in [:moves index] [dst src])
         (update :nmoves inc)
         (update-in [:moves-of dst] (fnil conj none) index)
         (update-in [:moves-of src] (fnil conj none) index)
         (update :worklist-moves conj index))
     index]))

(defn- entry-edges
  "Parameters arrive together, so they interfere with each other."
  [c alive]
  (let [params (:params (:f c))]
    (reduce (fn [c i]
              (let [param (nth params i)]
                (as-> c c
                  (reduce (fn [c other] (add-edge c param other)) c alive)
                  (reduce (fn [c another] (add-edge c param another))
                          c (drop (inc i) params)))))
            c (range (count params)))))

(defn- build [c]
  (let [f (:f c)
        l (live/analyse f)
        caller-saved (:caller (:machine c))
        c (assoc c :preferred (hints/preferences f))
        c (reduce (fn [c i]
                    (let [c (reduce node c (ir/uses i))]
                      (if (ir/defs i) (node c (ir/defs i)) c)))
                  c (for [b (ir/blocks f) i (ir/instrs b)] i))
        c (reduce node c (:params f))]
    (reduce
     (fn [c b]
       (let [[c alive]
             (reduce
              (fn [[c alive] i]
                (let [[c alive] (if (= (:op i) :move)
                                  (let [alive (disj alive (:src i))
                                        [c _] (add-move c (:dst i) (:src i))]
                                    [c alive])
                                  [c alive])
                      defined (ir/defs i)
                      [c alive] (if defined
                                  (let [alive (conj alive defined)]
                                    [(reduce (fn [c other] (add-edge c defined other))
                                             c alive)
                                     alive])
                                  [c alive])
                      ;; A value live across a call cannot sit in a caller-saved
                      ;; register.
                      c (if (= (:op i) :call)
                          (reduce (fn [c r]
                                    (if (= r defined)
                                      c
                                      (update-in c [:forbidden r] into caller-saved)))
                                  c alive)
                          c)
                      alive (if defined (disj alive defined) alive)]
                  [c (into alive (ir/uses i))]))
              [c (live/live-out l (:label b))]
              (reverse (ir/instrs b)))]
         (if (= (:label b) (:entry f)) (entry-edges c alive) c)))
     c (ir/blocks f))))

;; -- the worklists -----------------------------------------------------------

(defn- node-moves [c r]
  (filter #(or (contains? (:active-moves c) %) (contains? (:worklist-moves c) %))
          (get (:moves-of c) r none)))

(defn- move-related? [c r] (boolean (seq (node-moves c r))))

(defn- neighbours [c r]
  (remove #(or (contains? (:on-stack c) %) (contains? (:coalesced c) %))
          (adjacent c r)))

(defn- make-worklists [c]
  (reduce (fn [c r]
            (cond
              (>= (weight c r) (k c)) (update c :spill-wl conj r)
              (move-related? c r) (update c :freeze conj r)
              :else (update c :simplify conj r)))
          c (sort (keys (:adjacent c)))))

(defn- enable-moves [c nodes]
  (reduce (fn [c r]
            (reduce (fn [c index]
                      (if (contains? (:active-moves c) index)
                        (-> c (update :active-moves disj index)
                            (update :worklist-moves conj index))
                        c))
                    c (node-moves c r)))
          c nodes))

(defn- decrement-degree [c r]
  (let [was (weight c r)
        c (update-in c [:degree r] dec)]
    (if (not= was (k c))
      c
      ;; It has just become trivially colourable, so the copies around it may
      ;; have become safe to merge as well.
      (let [c (enable-moves c (conj (vec (neighbours c r)) r))
            c (update c :spill-wl disj r)]
        (if (move-related? c r)
          (update c :freeze conj r)
          (update c :simplify conj r))))))

(defn- simplify [c]
  (let [r (first (:simplify c))
        c (-> c
              (update :simplify disj r)
              (update :select-stack conj r)
              (update :on-stack conj r))]
    (reduce decrement-degree c (neighbours c r))))

;; -- coalescing --------------------------------------------------------------

(defn- get-alias [c r]
  (loop [r r] (if (contains? (:coalesced c) r) (recur (get (:alias c) r)) r)))

(defn- add-to-worklist [c r]
  (if (and (< (weight c r) (k c)) (not (move-related? c r)))
    (-> c (update :freeze disj r) (update :simplify conj r))
    c))

(defn- conservative?
  "Briggs: the merged node must have fewer than K significant neighbours.  The
  colours the two ends may not take add up as well, and a colour the merged node
  is barred from is one more thing standing in its way."
  [c u v]
  (let [together (into (set (neighbours c u)) (neighbours c v))
        barred (count (into (set (forbidden c u)) (forbidden c v)))
        significant (count (filter #(>= (weight c %) (k c)) together))]
    (< (+ significant barred) (k c))))

(defn- combine [c u v]
  (let [c (-> c
              (update :freeze disj v)
              (update :spill-wl disj v)
              (update :coalesced conj v)
              (assoc-in [:alias v] u)
              (update-in [:moves-of u] #(into (or % none) (get (:moves-of c) v none)))
              (update-in [:forbidden u] into (forbidden c v)))
        c (if (and (get (:preferred c) v) (not (get (:preferred c) u)))
            (assoc-in c [:preferred u] (get (:preferred c) v))
            c)
        c (enable-moves c [v])
        c (reduce (fn [c other] (decrement-degree (add-edge c other u) other))
                  c (neighbours c v))]
    (if (and (>= (weight c u) (k c)) (contains? (:freeze c) u))
      (-> c (update :freeze disj u) (update :spill-wl conj u))
      c)))

(defn- coalesce [c]
  (let [index (first (:worklist-moves c))
        [dst src] (get (:moves c) index)
        c (update c :worklist-moves disj index)
        u (get-alias c dst)
        v (get-alias c src)]
    (cond
      (= u v) (add-to-worklist c u)
      (contains? (adjacent c u) v) (-> c (add-to-worklist u) (add-to-worklist v))
      (conservative? c u v) (add-to-worklist (combine c u v) u)
      :else (update c :active-moves conj index))))

;; -- freezing and spilling ---------------------------------------------------

(defn- freeze-moves [c r]
  (reduce (fn [c index]
            (let [[dst src] (get (:moves c) index)
                  c (-> c (update :active-moves disj index)
                        (update :worklist-moves disj index))
                  end (if (= (get-alias c dst) (get-alias c r)) src dst)
                  other (get-alias c end)]
              (if (and (not (move-related? c other)) (< (weight c other) (k c)))
                (-> c (update :freeze disj other) (update :simplify conj other))
                c)))
          c (node-moves c r)))

(defn- freeze [c]
  (let [r (first (:freeze c))]
    (freeze-moves (-> c (update :freeze disj r) (update :simplify conj r)) r)))

(defn- select-spill
  "Guess that the value with the most neighbours per use will not fit.

  Never a reload, though: those are cheap by that measure precisely because they
  were made cheap, and choosing one would undo the last round's work instead of
  the pressure."
  [c]
  (let [weights (spill/costs (:f c))
        unprotected (remove #(contains? (:protected c) %) (:spill-wl c))
        among (if (empty? unprotected) (seq (:spill-wl c)) unprotected)
        score (fn [r] (/ (weight c r) (+ (get weights r 0.0) 1.0)))
        chosen (reduce (fn [best r] (if (> (score r) (score best)) r best))
                       (first among) (rest among))]
    (freeze-moves (-> c (update :spill-wl disj chosen) (update :simplify conj chosen))
                  chosen)))

;; -- handing out the colours -------------------------------------------------

(defn- assign-colours [c]
  (let [c (loop [c c]
            (if-let [r (first (:select-stack c))]
              (let [c (-> c (update :select-stack rest) (update :on-stack disj r))
                    taken (into #{} (keep #(get (:colour c) (get-alias c %))
                                          (adjacent c r)))
                    free (remove #(or (contains? taken %) (contains? (forbidden c r) %))
                                 (reg/anywhere (:machine c)))
                    want (get (:preferred c) r)]
                (recur
                 (if (empty? free)
                   (update c :spilled (fnil conj none) r)
                   (assoc-in c [:colour r]
                             (if (and want (some #{want} free)) want (first free))))))
              c))]
    (reduce (fn [c r]
              (assoc-in c [:colour r]
                        (get (:colour c) (get-alias c r)
                             (first (reg/anywhere (:machine c))))))
            (update c :spilled #(or % none))
            (:coalesced c))))

(defn- run [c]
  (loop [c (make-worklists (build c))]
    (cond
      (seq (:simplify c)) (recur (simplify c))
      (seq (:worklist-moves c)) (recur (coalesce c))
      (seq (:freeze c)) (recur (freeze c))
      (seq (:spill-wl c)) (recur (select-spill c))
      :else (assign-colours c))))

(defn allocate
  "Colour `f`, rewriting and starting again for as long as it spills.  What
  comes back is the function — which spilling rewrote — and its colouring."
  [f machine]
  (loop [f f slots {} protected #{}]
    (let [f (ir/recompute-preds f)
          c (run (new-colouring f machine protected))
          spilled (:spilled c)]
      (if (empty? spilled)
        [f (ir/allocation (:colour c)
                          (vec (sort (distinct (filter (set reg/CALLEE-SAVED)
                                                       (vals (:colour c))))))
                          slots)]
        (let [[f slots protected]
              (reduce (fn [[f slots protected] victim]
                        (when (contains? protected victim)
                          (spill/out-of-registers
                           (str "`" (:name f)
                                "` needs more registers at once than the machine has")))
                        (let [[f slots reloads] (spill/spill f victim slots)]
                          [f slots (into protected reloads)]))
                      [f slots protected] spilled)]
          (recur f slots protected))))))

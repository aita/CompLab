(ns wolv.copies
  "Doing several copies at once, one at a time.

  A phi is a copy that happens on an edge, and all the phis of a block happen
  together: every argument is read before any destination is written.  Once the
  allocator has given both ends real registers that is a permutation, and
  putting a permutation into a sequence of instructions is this namespace.

  Copies whose destination nobody else has still to read can go first.  When
  only cycles are left, something has to be got out of the way, and there are
  two ways to do it: a register the function never used can hold a value for one
  step, and if there is no such register the two ends of the cycle swap.  A swap
  is three `eor`s and needs nothing to borrow, which is why no register is
  reserved for this anywhere in the compiler.")

(defn mov [dst src] {:step :mov :dst dst :src src})
(defn swap [a b] {:step :swap :a a :b b})

(defn mov? [s] (= (:step s) :mov))
(defn swap? [s] (= (:step s) :swap))

(defn- moved
  "The value that was in `was` is in `now`; whoever wanted it looks there."
  [pending was now]
  (mapv (fn [[dst src]] (if (= src was) [dst now] [dst src]))
        ;; The swap already put it where it belongs.
        (remove (fn [[dst src]] (and (= src was) (= dst now))) pending)))

(defn sequentialize
  "Order `[destination source]` pairs so that nothing is lost on the way.
  `borrowed` is a register free to clobber, or nil."
  [moves borrowed]
  (let [real (filterv (fn [[dst src]] (not= dst src)) moves)]
    (when-not (= (count (distinct (map first real))) (count real))
      (throw (ex-info "a parallel copy writes a register twice" {})))
    ;; `pending` stays in the order it was given: which copy is picked when
    ;; several are ready is what the emitted sequence looks like.
    (loop [pending real done []]
      (if (empty? pending)
        done
        (let [sources (into #{} (map second pending))
              ready (filterv (complement sources) (map first pending))
              ready-set (set ready)]
          (cond
            (seq ready)
            (recur (filterv (fn [[dst _]] (not (ready-set dst))) pending)
                   (into done (map (fn [dst]
                                     (mov dst (second (first (filter #(= (first %) dst)
                                                                     pending)))))
                                   ready)))

            borrowed
            (let [stuck (first (first pending))]
              (recur (moved pending stuck borrowed) (conj done (mov borrowed stuck))))

            ;; Swapping satisfies `stuck` outright and leaves its old value where
            ;; the other end was, so everything still to read it reads there.
            :else
            (let [[stuck other] (first pending)]
              (recur (moved (rest pending) stuck other) (conj done (swap stuck other))))))))))

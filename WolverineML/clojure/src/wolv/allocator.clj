(ns wolv.allocator
  "The seam the allocator is reached through, and the verifier it answers to.

  There is one allocator here — leave SSA, build the interference graph, colour
  it with Chaitin's algorithm and George and Appel's iterated coalescing.  The
  Python tree has a second one that colours the SSA itself in dominance order,
  and keeps both so that the two can be measured against each other; this tree
  keeps the graph.

  What comes out is an allocation and not part of the function: a colouring is
  an assignment from the program's registers to the machine's, and nothing but
  the emitter and this verifier ever reads one.  Spilling rewrites the function
  it is colouring, though, so `allocate-module` answers with the module as well."
  (:require [wolv.graph :as graph]
            [wolv.ir :as ir]
            [wolv.liveness :as live]
            [wolv.registers :as reg]))

(defn allocate-module
  ([m] (allocate-module m (reg/whole-machine)))
  ([m machine]
   (let [[funcs allocs]
         (reduce (fn [[funcs allocs] f]
                   (let [[f alloc] (graph/allocate f machine)]
                     [(conj funcs f) (assoc allocs (:label f) alloc)]))
                 [[] {}] (:funcs m))]
     [(assoc m :funcs funcs) allocs])))

(defn verify
  "No two values that hold different things at once may share a colour.

  The check is made where the interference graph joins values — at each
  definition, and at the top of a block for the phis and the parameters, which
  define several at once.  Looking at a whole live set instead would be wrong,
  not merely slower: both ends of a copy are live after it and hold the same
  value, so they may share a register, and that is the entire point of
  coalescing.  A verifier that rejected it would reject every program the
  coalescer had done its job on.

  Every value that interferes with another is caught this way, because the later
  of the two definitions that put the values there happens while the other is
  live."
  [f alloc]
  (let [colours (:colours alloc)
        l (live/analyse f)
        coloured (fn [r]
                   (when-not (get colours r)
                     (throw (ex-info (str "%" r " has no colour") {}))))
        no-clash (fn [alive written where]
                   (when-let [colour (get colours written)]
                     (doseq [other alive
                             :when (and (not= other written)
                                        (= (get colours other) colour))]
                       (throw (ex-info (str "x" colour " holds %" written " and %" other
                                            " at once in " where) {})))))]
    (doseq [b (ir/blocks f)]
      (reduce (fn [alive i]
                (let [after (if (= (:op i) :move) (disj alive (:src i)) alive)
                      d (ir/defs i)]
                  (doseq [r (ir/uses i)] (coloured r))
                  (when d
                    (coloured d)
                    (no-clash (conj after d) d (:label b)))
                  (live/union (if d (disj after d) after) (live/regs (ir/uses i)))))
              (live/live-out l (:label b))
              (reverse (ir/instrs b)))
      (let [entering (reduce (fn [entering p]
                               (coloured (:dst p))
                               (let [with-phi (conj entering (:dst p))]
                                 (no-clash with-phi (:dst p) (:label b))
                                 with-phi))
                             (live/live-in l (:label b))
                             (:phis b))]
        (when (= (:label b) (:entry f))
          (reduce (fn [entering param]
                    (let [with-param (conj entering param)]
                      (no-clash with-param param (:label b))
                      with-param))
                  entering (:params f)))))
    f))

(defn verify-module [m allocs]
  (doseq [f (:funcs m)] (verify f (get allocs (:label f))))
  m)

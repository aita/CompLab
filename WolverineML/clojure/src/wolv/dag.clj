(ns wolv.dag
  "The data-flow DAG of one basic block.

  Instruction selection wants to see a block as expressions, not as a list:
  `a + (i << 3)` is one ARM instruction and `a + b*c` is another, and neither is
  visible while the operands are separate lines with names in between.  So each
  block is read into a graph — a node per instruction, an edge per operand — and
  the selector covers that graph with instructions.

  It is a graph and not a tree because a value can be read twice.  That is what
  `:users` counts, and it is what decides whether a node may be folded into the
  instruction that reads it or has to become an instruction of its own: a node
  read twice would otherwise be computed twice.  A value that leaves the block
  counts as read as well, and so does one a phi in a successor names.

  Only pure nodes are ever folded, and only into a reader whose instruction
  really absorbs them.  Both halves matter.  Folding moves a computation to
  where it is read, which is fine for arithmetic and not fine for a load,
  because a store in between would change what it reads; and folding a chain of
  nodes that nothing absorbs would move a whole expression to its last line,
  leaving every value it read alive until then.  So the selector plans first —
  it asks, of each node with one reader, whether that reader has a tile that
  takes it — and everything else is computed where it was written."
  (:require [clojure.string :as str]
            [wolv.ir :as ir]))

(defn node-value [n] (ir/defs (:instr n)))

(defn alone?
  "Read exactly once, inside the block, and computable where read."
  [n]
  (and n (= (:users n) 1) (not (:escapes? n)) (= (:op (:instr n)) :bin)))

(defn build
  "`live-out` includes what the phis of the successors will read."
  [b live-out]
  (let [[nodes by-value]
        (reduce (fn [[nodes by-value] [i instr]]
                  ;; `:operands` holds a node index for a value this block
                  ;; computed, and nil for one that came from outside it.
                  (let [operands (mapv #(get by-value %) (ir/uses instr))
                        d (ir/defs instr)]
                    [(conj nodes {:index i :instr instr :operands operands
                                  :users 0 :reader nil :escapes? false})
                     (if d (assoc by-value d i) by-value)]))
                [[] {}] (map-indexed vector (ir/instrs b)))
        counted (reduce
                 (fn [acc n]
                   (reduce (fn [acc operand]
                             (if operand
                               (let [read (acc operand)
                                     users (inc (:users read))]
                                 ;; `:reader` is the only node that reads it,
                                 ;; when there is one.
                                 (assoc acc operand
                                        (assoc read :users users
                                               :reader (when (= users 1) (:index n)))))
                               acc))
                           acc (:operands n)))
                 nodes nodes)
        escaping (mapv (fn [n]
                         (let [v (node-value n)]
                           (if (and v (contains? live-out v)) (assoc n :escapes? true) n)))
                       counted)]
    {:nodes escaping :by-value by-value}))

(defn node-of [g index] (when index (get (:nodes g) index)))
(defn node-count [g] (count (:nodes g)))

(defn rematerialisable
  "A constant, which costs nothing to repeat and is often not an instruction at
  all once it has become an immediate operand."
  [g index]
  (let [n (node-of g index)]
    (when (and n (not (:escapes? n)) (= (:op (:instr n)) :const)) n)))

(defn constant
  "The value at `index`, if it is a constant — however many read it.  Even one
  that has to exist in a register for somebody else can be an immediate here, so
  this asks less than `rematerialisable` does."
  [g index]
  (let [n (node-of g index)]
    (when (and n (= (:op (:instr n)) :const)) (:value (:instr n)))))

(defn- plain [r] (str "%" r))

(defn show [g]
  (str/join
   "\n"
   (map (fn [n]
          (let [reads (str/join ", " (map (fn [o] (if o (str o) "-")) (:operands n)))
                marks (str (if (:escapes? n) "*" "") (if (ir/effect? (:instr n)) "!" ""))]
            (format "  %3s%-2s %-38s reads [%s]  users %d"
                    (str (:index n)) marks
                    (ir/show-instr (:instr n) plain)
                    reads (:users n))))
        (:nodes g))))

(ns wolv.select
  "Instruction selection: cover the DAG with ARM instructions.

  Every node that has to become a register of its own is tiled, largest tile
  first, pulling its foldable operands into the tile as it goes.  The tiles are
  the things ARM can do in one instruction that the IR needs several nodes to
  say:

      a + b * c            madd
      a - b * c            msub
      a + (b << k)         add with a shifted operand
      a + 4095             add with an immediate
      a * 8                lsl
      [a + 24]             a load with the addition as its displacement
      a < b, then branch   cmp, and a branch on the flags

  What comes out is still the same CFG, and still in SSA — a tile defines one
  new register — so liveness, both allocators and the verifier carry on as
  before.  What has gone is the guesswork the emitter used to do with its
  peepholes: an instruction is now chosen where the whole expression is visible,
  rather than by looking at the line before."
  (:require [wolv.dag :as dag]
            [wolv.ir :as ir]
            [wolv.liveness :as live]
            [wolv.mach :as mach]))

(def IMMEDIATE
  "What `add`, `sub` and `cmp` take as an immediate operand."
  4095)

(def LOGICAL {"and" "and" "or" "orr" "xor" "eor"})
(def SHIFTS {"shl" "lsl" "shr" "asr"})

;; -- what the plan asks ------------------------------------------------------

(defn- bin? [n op]
  (and n (= (:op (:instr n)) :bin) (= (:oper (:instr n)) op)))

(defn- power-of-two? [value] (and (pos? value) (zero? (bit-and value (dec value)))))
(defn- log2 [value] (dec (- 64 (Long/numberOfLeadingZeros (long value)))))

(defn- as-shift
  "A `x << k` that can be folded, however it was written: `* 8` says it too.

  This decides nothing and emits nothing, so the plan and the tiles can both ask
  it and get the same answer."
  [g index]
  (let [n (dag/node-of g index)]
    (when (dag/alone? n)
      (let [i (:instr n)
            value (dag/constant g (second (:operands n)))
            amount (when value
                     (case (:oper i)
                       "*" (when (power-of-two? value) (log2 value))
                       "shl" value
                       nil))]
        (when (and amount (<= 0 amount) (< amount 64)) [n amount])))))

(defn- displaces
  "`[pointer + 24]`, when what is added to the pointer is a constant."
  [g n offset]
  (when (bin? n "+")
    (when-let [value (dag/constant g (second (:operands n)))]
      (let [total (+ offset value)]
        (cond
          (and (<= 0 total 32760) (zero? (mod total ir/WORD))) total
          (<= -256 total 255) total
          :else nil)))))

(defn- swallows?
  "Whether the instruction chosen for `reader` has room for `node`."
  [g reader n]
  (let [operands (:operands reader)
        i (:instr reader)]
    (case (:op i)
      :bin (boolean (and (contains? #{"+" "-"} (:oper i))
                         (= (second operands) (:index n))
                         (or (as-shift g (:index n)) (bin? n "*"))))
      :load (boolean (and (= (first operands) (:index n)) (displaces g n (:offset i))))
      :store (boolean (and (= (first operands) (:index n)) (displaces g n (:offset i))))
      false)))

(defn- plan
  "Decide which nodes a tile is going to swallow, before emitting any.

  Nothing may be deferred on the chance that its reader takes it.  A node left
  out of the order and then not absorbed would be computed at its reader
  instead, and a chain of those — `a + b + c + ...`, where every term has one
  reader — would move the whole sum to its last line and keep every term alive
  until then."
  [g]
  (into #{} (for [n (:nodes g)
                  :when (and (dag/alone? n) (:reader n)
                             (swallows? g (get (:nodes g) (:reader n)) n))]
              (:index n))))

;; -- emitting ----------------------------------------------------------------

(defn- machine
  ([s form dst srcs] (machine s form dst srcs 0 "" false))
  ([s form dst srcs imm] (machine s form dst srcs imm "" false))
  ([s form dst srcs imm symbol effect]
   (update s :out conj (ir/i-machine form dst srcs imm symbol effect))))

(declare tile)

(defn- at
  "The register holding an operand, computing it here if it was deferred.

  Only two kinds of node were left out of the order: a constant, which is tiled
  the first time somebody needs it in a register and read from there afterwards,
  and a node the plan said would be absorbed, which ends up here only if the
  tile that was to absorb it changed its mind."
  [s index reg]
  (let [g (:graph s)
        n (dag/node-of g index)]
    (cond
      (or (nil? n) (contains? (:done s) (:index n))) [s reg]

      (or (contains? (:absorbed s) (:index n)) (dag/rematerialisable g (:index n)))
      (tile (update s :done conj (:index n)) (:instr n) n)

      :else [s reg])))

(defn- force-operand
  "Compute a deferred operand for a reader that has no tile to take it."
  [s index]
  (let [n (dag/node-of (:graph s) index)]
    (if n (first (at s index (or (dag/node-value n) 0))) s)))

(defn- both
  "Both operands in registers, which is what the plain forms want."
  [s n lhs rhs]
  (let [[s left] (at s (first (:operands n)) lhs)
        [s right] (at s (second (:operands n)) rhs)]
    [s [left right]]))

(defn- multiply-into
  "`a + b * c` and `a - b * c` are one instruction each."
  [s n dst oper lhs]
  (let [product (dag/node-of (:graph s) (second (:operands n)))]
    (if-not (and (dag/alone? product) (bin? product "*"))
      [s false]
      (let [i (:instr product)
            [s a] (at s (first (:operands product)) (:lhs i))
            [s b] (at s (second (:operands product)) (:rhs i))
            [s c] (at s (first (:operands n)) lhs)]
        [(machine s (if (= oper "+") "madd" "msub") dst [a b c]) true]))))

(defn- shift-into
  "The second operand of an `add` may be shifted on the way in."
  [s n dst oper lhs]
  (if-let [[shifted amount] (as-shift (:graph s) (second (:operands n)))]
    (let [i (:instr shifted)
          [s base] (at s (first (:operands n)) lhs)
          [s other] (at s (first (:operands shifted)) (:lhs i))]
      [(machine s (if (= oper "+") "adds" "subs") dst [base other] amount) true])
    [s false]))

(defn- additive
  "`add` and `sub`, in whichever of their four forms fits."
  [s n dst oper lhs rhs]
  (let [left (first (:operands n))
        right (second (:operands n))
        ;; A shifted operand comes first: `a + b * 8` is one instruction that
        ;; way and two as a multiply-add, because the 8 would need a register.
        [s done?] (shift-into s n dst oper lhs)
        [s done?] (if done? [s true] (multiply-into s n dst oper lhs))]
    (if done?
      s
      (let [value (dag/constant (:graph s) right)]
        (if (and value (<= 0 value IMMEDIATE))
          (let [[s a] (at s left lhs)]
            (machine s (if (= oper "+") "addi" "subi") dst [a] value))
          ;; Only addition may take its constant from the other side.
          (let [other (when (= oper "+") (dag/constant (:graph s) left))]
            (if (and other (<= 0 other IMMEDIATE))
              (let [[s a] (at s right rhs)]
                (machine s "addi" dst [a] other))
              (let [[s operands] (both s n lhs rhs)]
                (machine s (if (= oper "+") "add" "sub") dst operands)))))))))

(defn- multiply [s n dst lhs rhs]
  (let [value (dag/constant (:graph s) (second (:operands n)))]
    (if (and value (power-of-two? value))
      (let [[s a] (at s (first (:operands n)) lhs)]
        (machine s "lsli" dst [a] (log2 value)))
      (let [[s operands] (both s n lhs rhs)]
        (machine s "mul" dst operands)))))

(defn- shift [s n dst oper lhs rhs]
  (let [value (dag/constant (:graph s) (second (:operands n)))]
    (if (and value (<= 0 value) (< value 64))
      (let [[s a] (at s (first (:operands n)) lhs)]
        (machine s (str (SHIFTS oper) "i") dst [a] value))
      (let [[s operands] (both s n lhs rhs)]
        (machine s (SHIFTS oper) dst operands)))))

(defn- logical [s n dst oper lhs rhs]
  ;; Which is how `not` arrives.
  (if (and (= oper "xor") (= (dag/constant (:graph s) (second (:operands n))) 1))
    (let [[s a] (at s (first (:operands n)) lhs)]
      (machine s "eori" dst [a] 1))
    (let [[s operands] (both s n lhs rhs)]
      (machine s (LOGICAL oper) dst operands))))

(defn- arithmetic [s n dst oper lhs rhs]
  (cond
    (contains? #{"+" "-"} oper) (additive s n dst oper lhs rhs)
    (= oper "*") (multiply s n dst lhs rhs)
    (= oper "/") (let [[s operands] (both s n lhs rhs)] (machine s "sdiv" dst operands))
    (contains? #{"shl" "shr"} oper) (shift s n dst oper lhs rhs)
    (contains? #{"and" "or" "xor"} oper) (logical s n dst oper lhs rhs)
    :else (throw (ex-info (str "no instruction for `" oper "`") {}))))

(defn- address
  "A pointer and a displacement, taking in an addition if there is one."
  [s index base offset]
  (let [n (dag/node-of (:graph s) index)
        displaced (when (dag/alone? n) (displaces (:graph s) n offset))]
    (if displaced
      (let [[s p] (at s (first (:operands n)) (:lhs (:instr n)))] [s p displaced])
      (let [[s p] (at s index base)] [s p offset]))))

(defn- compare-op [s n oper lhs rhs]
  (let [left (first (:operands n))
        right (second (:operands n))
        value (dag/constant (:graph s) right)]
    (if (and value (<= 0 value IMMEDIATE))
      (let [[s a] (at s left lhs)] (machine s "cmpi" nil [a] value))
      (let [[s operands] (both s n lhs rhs)] (machine s "cmp" nil operands)))))

;; -- one node ----------------------------------------------------------------

(defmulti tile
  "Emit the instruction this node becomes, and answer with the register it left
  its value in."
  (fn [_s i _n] (:op i)))

(defmethod tile :const [s i _]
  [(machine s "const" (:dst i) [] (:value i)) (:dst i)])

(defmethod tile :str-const [s i _]
  [(machine s "adr" (:dst i) [] 0 (:symbol i) false) (:dst i)])

(defmethod tile :bin [s i n]
  [(arithmetic s n (:dst i) (:oper i) (:lhs i) (:rhs i)) (:dst i)])

(defmethod tile :cmp [s i n]
  (let [s (compare-op s n (:oper i) (:lhs i) (:rhs i))]
    [(machine s "cset" (:dst i) [] 0 (mach/condition-of (:oper i)) false) (:dst i)]))

(defmethod tile :load [s i n]
  (let [[s pointer displaced] (address s (first (:operands n)) (:base i) (:offset i))]
    [(machine s "ldr" (:dst i) [pointer] displaced) (:dst i)]))

(defmethod tile :store [s i n]
  (let [[s value] (at s (second (:operands n)) (:src i))
        [s pointer displaced] (address s (first (:operands n)) (:base i) (:offset i))]
    [(machine s "str" nil [pointer value] displaced "" true) (:src i)]))

;; Moves, calls, slot accesses and the terminator are machine instructions
;; already, and a phi is not in this list at all.  None of them folds anything,
;; so every operand that was left to be folded has to be computed here instead.
(defmethod tile :default [s i n]
  (let [s (reduce force-operand s (:operands n))
        i (if (and (= (:op i) :cbr) (:fused s)) (assoc i :code (:fused s)) i)]
    [(update s :out conj i) (or (ir/defs i) 0)]))

;; -- comparisons and the branch that reads them ------------------------------

(defn- fuse-comparison
  "A comparison the branch below it is the only reader of sets the flags."
  [s index]
  (let [g (:graph s)
        n (dag/node-of g index)
        i (:instr n)
        final (:instr (get (:nodes g) (dec (dag/node-count g))))]
    (if (and (= (:op i) :cmp)
             (= (:op final) :cbr)
             (= (inc index) (dec (dag/node-count g)))
             (= (:test final) (:dst i))
             (= (:users n) 1)
             (not (:escapes? n)))
      [(assoc (compare-op s n (:oper i) (:lhs i) (:rhs i))
              :fused (mach/condition-of (:oper i)))
       true]
      [s false])))

(defn- run [g]
  (:out (reduce (fn [s index]
                  (if (or (contains? (:absorbed s) index) (dag/rematerialisable g index))
                    s
                    (let [[s fused?] (fuse-comparison s index)]
                      (if fused?
                        s
                        (let [n (get (:nodes g) index)]
                          (first (tile (update s :done conj index) (:instr n) n)))))))
                {:graph g :out [] :done #{} :absorbed (plan g) :fused nil}
                (range (dag/node-count g)))))

(defn select [f]
  (let [l (live/analyse f)]
    (reduce (fn [f label]
              (let [b (ir/block-of f label)]
                (ir/set-instrs f label (run (dag/build b (live/live-out l label))))))
            f (:order f))))

(defn select-module [m] (update m :funcs #(mapv select %)))

(defn graphs
  "The DAGs a selection would work on, for `wolv emit -s dag`."
  [f]
  (let [l (live/analyse f)]
    (map (fn [b] [(:label b) (dag/build b (live/live-out l (:label b)))]) (ir/blocks f))))

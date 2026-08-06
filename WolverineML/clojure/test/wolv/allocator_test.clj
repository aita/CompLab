(ns wolv.allocator-test
  "The allocator, the parallel copies, and what the emitter does with them."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [wolv.allocator :as allocator]
            [wolv.copies :as copies]
            [wolv.driver :as driver]
            [wolv.ir :as ir]
            [wolv.liveness :as live]
            [wolv.lower :as lower]
            [wolv.opt :as opt]
            [wolv.outofssa :as outofssa]
            [wolv.parser :as parser]
            [wolv.registers :as reg]
            [wolv.ssa :as ssa]
            [wolv.typecheck :as typecheck]
            [wolv.typecheck-test :refer [lines]]))

(def SOURCE
  (lines "type point = { x : int, y : int }"
         ""
         "fun busy (n : int) : int ="
         "  let"
         "    var a = n + 1"
         "    var b = n + 2"
         "    var c = n + 3"
         "    var d = n + 4"
         "    var total = 0"
         "  in"
         "    while a < n * 10 do ("
         "      total := total + a * b + c * d;"
         "      a := a + 1;"
         "      b := b + 2;"
         "      c := c + 3;"
         "      d := d + 4"
         "    );"
         "    total"
         "  end"
         ""
         "fun caller (n : int) : int = busy (n) + busy (n + 1) + busy (n + 2)"
         ""
         "val p = point { x = 1, y = 2 }"
         "val () = printInt (caller (3) + p.x)"))

(defn prepared
  "The pipeline up to the point where the allocator takes over."
  ([] (prepared SOURCE))
  ([source]
   (let [{:keys [program escapes]} (typecheck/check (parser/parse source))]
     (-> (lower/lower program escapes (lower/options true))
         ssa/construct-module
         opt/optimise
         (update :funcs #(mapv ssa/split-critical-edges %))
         outofssa/destruct-module))))

(defn instructions [f] (vec (for [b (ir/blocks f) i (ir/instrs b)] i)))

(defn moves-left [m allocs]
  (count (for [f (:funcs m)
               :let [c (:colours (get allocs (:label f)))]
               i (instructions f)
               :when (and (= (:op i) :move)
                          (not= (get c (:dst i)) (get c (:src i))))]
           i)))

;; -- what the colouring promises ---------------------------------------------

(deftest every-value-gets-a-colour
  (let [[m allocs] (allocator/allocate-module (prepared))]
    (doseq [f (:funcs m)
            :let [colours (:colours (get allocs (:label f)))]
            i (instructions f)]
      (doseq [r (ir/uses i)] (is (get colours r)))
      (when (ir/defs i) (is (get colours (ir/defs i)))))))

(deftest values-live-together-differ
  (let [[m allocs] (allocator/allocate-module (prepared))]
    (doseq [f (:funcs m)] (is (allocator/verify f (get allocs (:label f)))))))

(deftest the-verifier-rejects-a-real-clash
  ;; One colour for everything is wrong, and has to be said so.  Without this,
  ;; weakening the verifier enough to accept a coalesced copy would go unnoticed
  ;; if it also stopped saying anything at all.
  (let [[m allocs] (allocator/allocate-module (prepared))]
    (doseq [f (:funcs m)
            :let [alloc (get allocs (:label f))
                  colours (:colours alloc)]
            :when (> (count (distinct (vals colours))) 1)]
      (is (thrown-with-msg?
           clojure.lang.ExceptionInfo #"at once"
           (allocator/verify f (assoc alloc :colours (zipmap (keys colours) (repeat 0)))))))))

(deftest the-verifier-accepts-a-coalesced-copy
  ;; Both ends of a copy are live after it, and hold the same value.  Coalescing
  ;; gives them one register, so a verifier that read a whole live set and
  ;; complained would reject every program it had worked on.
  (let [f (ir/add-block (ir/new-func "f" "f" 0) "entry")
        [f a] (ir/new-reg f)
        [f b] (ir/new-reg f)
        f (-> f
              (ir/emit "entry" (ir/i-const a 1))
              (ir/emit "entry" (ir/i-move b a))
              (ir/emit "entry" (ir/i-call nil "wol_print_int" [a]))
              (ir/emit "entry" (ir/i-ret b))
              ir/recompute-preds)]
    (is (allocator/verify f (ir/allocation {a 9 b 9} [] {})))))

(deftest a-value-live-across-a-call-is-callee-saved
  (let [[m allocs] (allocator/allocate-module (prepared))]
    (doseq [f (:funcs m)
            :let [colours (:colours (get allocs (:label f)))]
            r (live/across-calls f (live/analyse f))]
      (is (some #{(get colours r)} reg/CALLEE-SAVED)))))

(deftest only-the-callee-saved-it-used-are-saved
  (let [[m allocs] (allocator/allocate-module (prepared))]
    (doseq [f (:funcs m)
            :let [alloc (get allocs (:label f))]]
      (is (= (set (:saved alloc))
             (set (filter (set reg/CALLEE-SAVED) (vals (:colours alloc)))))))))

(deftest a-smaller-machine-still-works
  (doseq [size [5 6 8 12 16 26]
          :let [machine (reg/limited size)
                [m allocs] (allocator/allocate-module (prepared) machine)]
          f (:funcs m)
          :let [alloc (get allocs (:label f))]]
    (is (allocator/verify f alloc))
    (doseq [colour (vals (:colours alloc))]
      (is (some #{colour} (reg/anywhere machine))))))

(deftest a-small-machine-spills
  (let [[m allocs] (allocator/allocate-module (prepared) (reg/limited 6))]
    (is (some #(pos? (count (:spilled (get allocs (:label %))))) (:funcs m))
        "nothing spilled")
    (doseq [f (:funcs m)
            slot (vals (:spilled (get allocs (:label f))))]
      (is (< slot (:nslots f))))))

(deftest pressure-falls-to-what-the-machine-has
  (let [machine (reg/limited 5)
        [m _] (allocator/allocate-module (prepared) machine)]
    (doseq [f (:funcs m)]
      (is (<= (live/pressure f (live/analyse f)) (reg/register-count machine))))))

(deftest an-impossible-demand-is-reported
  (let [m (prepared
           (lines "fun ten (a : int, b : int, c : int, d : int, e : int,"
                  "         f : int, g : int, h : int, i : int, j : int) : int = a + j"
                  "val () = printInt (ten (1, 2, 3, 4, 5, 6, 7, 8, 9, 10))"))]
    (is (thrown-with-msg? clojure.lang.ExceptionInfo #"more registers"
                          (allocator/allocate-module m (reg/limited 8))))))

;; -- what coalescing is for --------------------------------------------------

(deftest leaving-ssa-removes-every-phi
  (doseq [f (:funcs (prepared)) b (ir/blocks f)]
    (is (empty? (:phis b)))))

(deftest leaving-ssa-makes-copies-and-coalescing-eats-them
  (let [m (prepared)
        before (count (for [f (:funcs m) i (instructions f) :when (= (:op i) :move)] i))
        [m allocs] (allocator/allocate-module m)]
    (is (pos? before) "leaving SSA should have made copies")
    (is (<= (moves-left m allocs) (quot before 10))
        (str (moves-left m allocs) " of " before " copies survived"))))

;; -- parallel copies ---------------------------------------------------------

(defn- perform
  "Run a parallel copy on a register file, so the permutation can be checked.
  This is what caught a swap the ordering was doing twice."
  [steps state]
  (reduce (fn [state step]
            (if (copies/mov? step)
              (assoc state (:dst step) (get state (:src step)))
              (assoc state (:a step) (get state (:b step)) (:b step) (get state (:a step)))))
          state steps))

(defn- worked [moves borrowed]
  (let [before (into {} (map (fn [r] [r (str "v" r)]) (range 32)))
        steps (copies/sequentialize moves borrowed)
        after (perform steps before)]
    (doseq [[dst src] moves]
      (is (= (get before src) (get after dst))
          (str "x" dst " should hold v" src)))
    steps))

(deftest a-copy-with-no-cycle-is-just-moves
  (let [steps (worked [[1 2] [3 4] [5 5]] 9)]
    (is (every? copies/mov? steps))
    (is (= 2 (count steps)))))

(deftest a-chain-is-ordered-so-nothing-is-lost
  (is (worked [[1 2] [2 3] [3 4]] 9)))

(deftest a-cycle-borrows-a-register-when-there-is-one
  (let [steps (worked [[1 2] [2 1]] 9)]
    (is (every? copies/mov? steps))
    (is (some #(= 9 (:dst %)) steps))))

(deftest a-cycle-swaps-when-there-is-nothing-to-borrow
  (is (= [true] (mapv copies/swap? (worked [[1 2] [2 1]] nil)))))

(deftest a-longer-cycle-swaps-its-way-round
  (let [steps (worked [[1 2] [2 3] [3 1]] nil)]
    (is (every? copies/swap? steps))
    (is (= 2 (count steps)))))

(deftest two-cycles-at-once
  (is (worked [[1 2] [2 1] [3 4] [4 3]] nil))
  (is (worked [[1 2] [2 1] [3 4] [4 3]] 9)))

;; -- what the scratch registers used to be for -------------------------------

(deftest the-remainder-is-a-divide-and-an-msub
  (let [text (driver/compile-to-asm
              "fun f (a : int, b : int) : int = a mod b\nval () = printInt (f (7, 2))"
              (driver/default-options))]
    (is (= 1 (count (re-seq #"sdiv" text))))
    (is (= 1 (count (re-seq #"msub" text))))
    (is (not (str/includes? text "mul")))))

(deftest ordinary-code-keeps-no-register-back
  ;; x17 is only for an address the emitter cannot reach any other way.
  (is (not (str/includes? (driver/compile-to-asm (slurp "examples/tour.wol")
                                                 (driver/default-options))
                          "x17"))))

(deftest x16-is-allocatable
  ;; It used to be held back for the emitter; a busy function should take it.
  (is (str/includes? (driver/compile-to-asm (slurp "test/programs/pressure.wol")
                                            (driver/default-options))
                     "x16")))

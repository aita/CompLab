(ns wolv.middle-test
  "SSA construction, the optimiser, and instruction selection."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [wolv.dag :as dag]
            [wolv.driver :as driver]
            [wolv.ir :as ir]
            [wolv.liveness :as live]
            [wolv.lower :as lower]
            [wolv.opt :as opt]
            [wolv.parser :as parser]
            [wolv.select :as select]
            [wolv.ssa :as ssa]
            [wolv.typecheck :as typecheck]
            [wolv.typecheck-test :refer [lines]]))

(defn build-ir
  ([source] (build-ir source false))
  ([source checks?]
   (let [{:keys [program escapes]} (typecheck/check (parser/parse source))]
     (lower/lower program escapes (lower/options checks?)))))

(defn in-ssa
  ([source] (in-ssa source false))
  ([source checks?] (ssa/construct-module (build-ir source checks?))))

(defn selected
  ([source] (selected source false))
  ([source checks?]
   (-> (in-ssa source checks?)
       opt/optimise
       (update :funcs #(mapv ssa/split-critical-edges %))
       select/select-module)))

(defn func-named [m name] (first (filter #(= (:name %) name) (:funcs m))))

(defn instructions [f] (vec (for [b (ir/blocks f) i (ir/instrs b)] i)))

(defn forms
  "The instruction forms chosen inside one function, the caller's aside."
  ([source] (forms source "f" false))
  ([source name] (forms source name false))
  ([source name checks?]
   (vec (keep :form (filter #(= (:op %) :machine)
                            (instructions (func-named (selected source checks?) name)))))))

(defn count-of [xs x] (count (filter #(= % x) xs)))

(def LOOP
  (lines "fun count (n : int) : int ="
         "  let var i = 0"
         "      var total = 0"
         "  in"
         "    while i < n do (total := total + i; i := i + 1);"
         "    total"
         "  end"
         "val () = printInt (count (10))"))

(defn function [body]
  (str "fun f (a : int, b : int, c : int) : int = " body
       "\nval () = printInt (f (1, 2, 3))"))

;; -- SSA ---------------------------------------------------------------------

(deftest lowering-writes-a-variable-more-than-once
  (let [f (second (:funcs (build-ir LOOP)))
        written (frequencies (keep ir/defs (instructions f)))]
    (is (some #(> % 1) (vals written)))
    (is (every? #(empty? (:phis %)) (ir/blocks f)))))

(deftest construction-gives-one-definition-and-phis
  (let [f (second (:funcs (in-ssa LOOP)))]
    (ssa/verify f)
    (is (some #(seq (:phis %)) (ir/blocks f)) "a loop needs phis")))

(deftest every-function-of-the-tour-verifies
  (doseq [f (:funcs (in-ssa (slurp "examples/tour.wol") true))]
    (is (ssa/verify f))))

(deftest the-dominators-of-a-diamond
  (let [f (second (:funcs (in-ssa (lines "fun f (c : bool) : int = if c then 1 else 2"
                                         "val () = printInt (f (true))"))))
        dom (ssa/dominance-of f)
        joins (filter #(> (count (:preds %)) 1) (ir/blocks f))]
    (is (every? #(ssa/dominates? dom (:entry f) %) (:order f)))
    (is (seq joins) "a diamond has a join")
    (doseq [join joins]
      (is (= (:entry f) (get (:idom dom) (:label join)))))))

(deftest a-phi-names-exactly-its-predecessors
  (doseq [f (:funcs (in-ssa LOOP))
          b (ir/blocks f)
          p (:phis b)]
    (is (= (sort (ir/phi-preds p)) (sort (:preds b))))))

;; -- the optimiser -----------------------------------------------------------

(deftest constants-fold
  (let [m (opt/optimise (in-ssa "val () = printInt (2 * 3 + 4)"))]
    (is (= [10] (mapv :value (filter #(= (:op %) :const)
                                     (instructions (first (:funcs m)))))))))

(deftest dead-code-goes
  (let [m (opt/optimise
           (in-ssa (lines "fun f (n : int) : int = let val unused = n * n in n + 1 end"
                          "val () = printInt (f (2))")))]
    (is (not-any? #(and (= (:op %) :bin) (= (:oper %) "*"))
                  (instructions (second (:funcs m)))))))

(deftest unreachable-blocks-go
  (let [m (opt/optimise (in-ssa "val () = if true then print (\"a\") else print (\"b\")"))]
    (is (= ["wol_print"] (mapv :callee (filter #(= (:op %) :call)
                                               (instructions (first (:funcs m)))))))))

(deftest splitting-leaves-phis-only-after-a-jump
  (doseq [f (:funcs (opt/optimise (in-ssa LOOP true)))]
    (let [f (ssa/split-critical-edges f)]
      (ssa/verify f)
      (doseq [b (ir/blocks f) :when (> (count (ir/succs b)) 1)
              succ (ir/succs b)]
        (is (empty? (:phis (ir/block-of f succ))))))))

;; -- the tiles ---------------------------------------------------------------

(deftest multiply-add-is-one-instruction
  (let [chosen (forms (function "a + b * c"))]
    (is (some #{"madd"} chosen))
    (is (not-any? #{"mul"} chosen))))

(deftest multiply-subtract-is-one-instruction
  (let [chosen (forms (function "a - b * c"))]
    (is (some #{"msub"} chosen))
    (is (not-any? #{"mul"} chosen))))

(deftest a-shifted-operand-beats-a-multiply-add
  ;; `a + b * 8` is one instruction with a shift and two as a multiply-add.
  (let [chosen (forms (function "a + b * 8"))]
    (is (= 1 (count-of chosen "adds")))
    (is (not-any? #{"madd"} chosen))
    (is (not-any? #{"lsli"} chosen))))

(deftest a-small-constant-is-an-immediate
  (is (= ["addi"] (forms (function "a + 5"))))
  (is (= ["addi" "subi"] (forms (function "(a + 5) - 7")))))

(deftest a-large-constant-is-not
  (is (some #{"const"} (forms (function "a + 100000")))))

(deftest a-multiply-by-a-power-of-two-is-a-shift
  (let [chosen (forms (function "a * 8"))]
    (is (some #{"lsli"} chosen))
    (is (not-any? #{"mul"} chosen))))

(deftest a-comparison-read-only-by-its-branch-sets-the-flags
  (let [source (lines "fun f (a : int) : int = if a < 3 then 1 else 2"
                      "val () = printInt (f (1))")
        codes (for [f (:funcs (selected source))
                    b (ir/blocks f)
                    :let [t (ir/terminator b)]
                    :when (= (:op t) :cbr)]
                (:code t))]
    (is (some #{"lt"} codes))
    (is (not-any? #{"cset"} (forms source)))))

(deftest a-comparison-read-by-something-else-is-a-value
  (is (some #{"cset"}
            (forms "fun f (a : int) : bool = a < 3\nval () = print (\"x\")"))))

(deftest an-array-element-takes-two-instructions
  (let [text (driver/compile-to-asm
              "val a = array (4, 0)\nval () = printInt (a[2] + a[3])"
              (driver/options false true nil))]
    (is (= 2 (count (filter #(str/starts-with? % "\tldr ") (str/split-lines text)))))))

;; -- what the plan is for ----------------------------------------------------

(deftest a-constant-read-twice-is-still-an-immediate
  ;; It costs nothing to repeat, so two readers may both take it.
  (let [chosen (forms (function "(a + 1) * (b + 1)"))]
    (is (= 2 (count-of chosen "addi")))
    (is (not-any? #{"const"} chosen))))

(deftest a-chain-of-additions-is-not-deferred-to-its-last-line
  ;; Folding a whole spine would keep every term live until the end.
  (let [m (selected
           (lines "fun sum (a : int, b : int, c : int, d : int, e : int, f : int) : int ="
                  "  a + b + c + d + e + f"
                  "val () = printInt (sum (1, 2, 3, 4, 5, 6))"))
        f (func-named m "sum")]
    (is (<= (live/pressure f (live/analyse f)) 8))))

(deftest a-node-read-twice-is-computed-once
  (is (= 1 (count-of (forms (function "let val t = a * b in t + t end")) "mul"))))

(deftest the-graph-counts-its-readers
  (let [f (func-named (selected (function "a + b")) "f")
        l (live/analyse f)]
    (doseq [b (ir/blocks f)]
      (let [g (dag/build b (live/live-out l (:label b)))]
        (doseq [n (:nodes g)]
          (is (= (:users n)
                 (count (filter #(= % (:index n))
                                (mapcat :operands (:nodes g)))))))))))

(deftest selection-keeps-it-in-ssa
  (doseq [f (:funcs (selected (function "a + b * c + 8") true))]
    (is (ssa/verify f))))

(ns wolv.random-test
  "Random programs, compiled and checked against what the oracle says they mean."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [wolv.driver :as driver]
            [wolv.emit :as emit]
            [wolv.oracle :as oracle]
            [wolv.typecheck-test :refer [lines]]))

(def CONFIGURATIONS
  [["default" (driver/options true true nil)]
   ["no-opt" (driver/options true false nil)]
   ["spilling" (driver/options true true 10)]])

(defn agrees
  "The first line that differs is the useful part of the answer."
  [source expected opts what]
  (let [done (driver/run source opts)
        got (str/split-lines (:stdout done))
        want (str/split-lines expected)]
    (is (= 0 (:code done)) (:stderr done))
    (doseq [[i g w] (map vector (range) got want)]
      (is (= w g) (str what ", line " i)))
    (is (= (count want) (count got)) what)))

(deftest arithmetic
  (when (driver/toolchain-ready?)
    (doseq [seed [1 2]
            :let [[source expected] (oracle/arithmetic seed 25)]
            [what opts] CONFIGURATIONS]
      (agrees source expected opts (str "arithmetic " seed " [" what "]")))))

(deftest arrays-loops-and-branches
  (when (driver/toolchain-ready?)
    (doseq [seed [1 2]
            :let [[source expected] (oracle/imperative seed 8)]
            [what opts] CONFIGURATIONS]
      (agrees source expected opts (str "imperative " seed " [" what "]")))))

(deftest a-cycle-of-copies-can-be-done-without-a-scratch-register
  ;; The recursive call swaps its two arguments, so the copies into `x0` and
  ;; `x1` are a cycle that has to be untangled somehow.  The borrowed register
  ;; is what usually hides the other path.
  (when (driver/toolchain-ready?)
    (let [source (lines "fun swap (a : int, b : int) : int ="
                        "  if a > b then swap (b, a) else b * 10 + a"
                        "val () = (printInt (swap (1, 2)); print (\" \"); printInt (swap (7, 3)))")]
      (is (= "21 73" (:stdout (driver/run source (driver/default-options)))))
      (binding [emit/*borrow-nothing* true]
        (is (str/includes? (driver/compile-to-asm source (driver/default-options)) "eor x")
            "no swap was written")
        (is (= "21 73" (:stdout (driver/run source (driver/default-options)))))))))

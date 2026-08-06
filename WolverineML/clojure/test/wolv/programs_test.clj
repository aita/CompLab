(ns wolv.programs-test
  "End to end: compile to ARMv8, assemble, link, and run it.

  These are the only tests that need a toolchain.  Without a cross `gcc` and
  `qemu-aarch64` they skip rather than fail, so the rest of the suite still runs
  on a machine that has neither."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [wolv.driver :as driver]
            [wolv.typecheck-test :refer [lines]]))

(defn wol-files [directory]
  (sort (filter #(str/ends-with? % ".wol") (map #(.getName %) (.listFiles (io/file directory))))))

(def CONFIGURATIONS
  [["default" (driver/options true true nil)]
   ["no-opt" (driver/options true false nil)]
   ["no-checks" (driver/options false true nil)]
   ["spilling" (driver/options true true 12)]
   ["spilling-no-opt" (driver/options true false 12)]])

(defn ran
  ([source opts] (ran source opts ""))
  ([source opts stdin]
   (let [done (driver/run source opts stdin)]
     (is (= 0 (:code done)) (:stderr done))
     (:stdout done))))

(deftest every-option-gives-the-same-answer
  (when (driver/toolchain-ready?)
    (doseq [name (wol-files "test/programs")
            :let [source (slurp (str "test/programs/" name))
                  want (slurp (str "test/programs/" (str/replace name #"\.wol$" ".out")))]
            [what opts] CONFIGURATIONS]
      (is (= want (ran source opts)) (str name " [" what "]")))))

(deftest the-examples-agree-with-themselves
  ;; No expected output on file: what matters is that the stages agree.
  (when (driver/toolchain-ready?)
    (doseq [name (wol-files "examples")
            :let [source (slurp (str "examples/" name))
                  baseline (ran source (driver/default-options))]]
      (is (pos? (count baseline)))
      (doseq [[what opts] (rest CONFIGURATIONS)
              :when (not= what "no-checks")]
        (is (= baseline (ran source opts)) (str name " [" what "]"))))))

(deftest the-checks-catch-what-they-are-for
  (when (driver/toolchain-ready?)
    (doseq [[source message]
            [["val a = array (3, 0)\nval () = printInt (a[5])" "outside an array"]
             [(lines "type t = { x : int }" "val n : t = nil" "val () = printInt (n.x)")
              "field of nil"]
             ["var z = 0\nval () = printInt (7 / z)" "division by zero"]]]
      (let [done (driver/run source (driver/default-options))]
        (is (= 1 (:code done)))
        (is (str/includes? (:stderr done) message) message)))))

(deftest a-check-can-be-turned-off
  (when (driver/toolchain-ready?)
    (is (= "0" (ran "val a = array (3, 0)\nval () = printInt (a[1])\n"
                    (driver/options false true nil))))))

(deftest standard-input
  (when (driver/toolchain-ready?)
    (is (= "read: hello (5)\n"
           (ran (lines "var line = \"\""
                       "var c = getChar ()"
                       "val () = while c <> \"\" andalso c <> \"\\n\" do (line := line ^ c; c := getChar ())"
                       "val () = print (\"read: \" ^ line ^ \" (\" ^ intToString (size (line)) ^ \")\\n\")")
                (driver/default-options)
                "hello\n")))))

(deftest the-exit-code-is-the-programs
  (when (driver/toolchain-ready?)
    (let [done (driver/run "val () = (print (\"bye\\n\"); exit (3))" (driver/default-options))]
      (is (= 3 (:code done)))
      (is (= "bye\n" (:stdout done))))))

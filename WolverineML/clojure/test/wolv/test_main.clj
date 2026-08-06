(ns wolv.test-main
  "Run every suite, and leave an exit status behind."
  (:require [clojure.test :as test]))

(def SUITES
  '[wolv.lexer-test
    wolv.parser-test
    wolv.typecheck-test
    wolv.middle-test
    wolv.allocator-test
    wolv.programs-test
    wolv.random-test])

(defn -main [& _]
  (apply require SUITES)
  (let [summary (apply test/run-tests SUITES)]
    (shutdown-agents)
    (System/exit (if (and (zero? (:fail summary)) (zero? (:error summary))) 0 1))))

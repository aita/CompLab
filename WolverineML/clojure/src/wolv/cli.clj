(ns wolv.cli
  "The command line.

  The arguments are picked apart by hand rather than by `clojure.tools.cli`,
  which is a dependency this tree does not have and which would stop reading
  flags at the first thing that is not one: `wolv emit -s ssa prog.wol` puts a
  flag after two of them, and every other tree in this repository accepts that."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [wolv.diag :as diag]
            [wolv.driver :as driver])
  (:gen-class))

(def ^:private COMMANDS #{"build" "run" "emit" "check"})

(def ^:private USAGE
  (str/join
   "\n"
   ["usage: wolv <command> <file> [options]"
    ""
    "  build   compile and link an executable"
    "  run     build it and run it"
    "  emit    write one stage of the pipeline to standard output"
    "  check   types only"
    ""
    "  -o, --out PATH     where `build` should write the executable"
    "  -s, --stage NAME   which stage `emit` should show:"
    "                     tokens, ast, ir, ssa, opt, dag, mach, flat, ra, asm"
    "      --no-checks    leave out the nil, bounds and divide-by-zero checks"
    "      --no-opt       do not optimise the SSA"
    "      --max-regs N   pretend the machine has N registers, to make it spill"]))

(defn- bad [message]
  (binding [*out* *err*] (println (str "wolv: " message)))
  (System/exit 1))

(defn- complain [message]
  (binding [*out* *err*] (println message))
  1)

(defn- parse-arguments [argv]
  (loop [args argv
         so-far {:checks? true :optimise? true :max-regs nil :stage "asm" :out nil :rest []}]
    (if (empty? args)
      so-far
      (let [arg (first args)
            value (fn [] (if (empty? (rest args))
                           (bad (str "`" arg "` wants a value after it"))
                           (second args)))]
        (cond
          (contains? #{"-h" "--help"} arg) (do (println USAGE) (System/exit 0))
          (contains? #{"-o" "--out"} arg) (recur (drop 2 args) (assoc so-far :out (value)))
          (contains? #{"-s" "--stage"} arg)
          (let [v (value)]
            (when-not (some #{v} driver/STAGES) (bad (str "no such stage as `" v "`")))
            (recur (drop 2 args) (assoc so-far :stage v)))

          (= arg "--max-regs")
          (let [n (try (Long/parseLong (value)) (catch Exception _ nil))]
            (when-not (and n (pos? n)) (bad "`--max-regs` wants a number"))
            (recur (drop 2 args) (assoc so-far :max-regs n)))

          (= arg "--no-checks") (recur (rest args) (assoc so-far :checks? false))
          (= arg "--no-opt") (recur (rest args) (assoc so-far :optimise? false))
          (and (> (count arg) 1) (str/starts-with? arg "-"))
          (bad (str "no such option as `" arg "`"))

          :else (recur (rest args) (update so-far :rest conj arg)))))))

(defn- drop-suffix
  "A `.wol` file becomes an executable of the same name without the suffix."
  [file]
  (if (str/ends-with? file ".wol") (subs file 0 (- (count file) 4)) (str file ".out")))

(defn- from-stdin []
  (if (nil? (System/console)) (slurp *in*) ""))

(defn- do-command [command file source opts args]
  (case command
    "check" (do (driver/to-ir source opts) 0)
    "emit" (do (print (driver/stage source (:stage args) opts)) (flush) 0)
    "build" (do (driver/build source (or (:out args) (drop-suffix file)) opts) 0)
    (let [done (driver/run source opts (from-stdin))]
      (print (:stdout done))
      (flush)
      (binding [*out* *err*] (print (:stderr done)) (flush))
      (:code done))))

(defn- wolv-main [argv]
  (let [args (parse-arguments argv)
        positional (:rest args)]
    (when-not (= 2 (count positional)) (bad "wants a command and a file"))
    (let [command (first positional)
          file (second positional)]
      (when-not (contains? COMMANDS command)
        (bad (str "no such command as `" command "`: " (str/join ", " (sort COMMANDS)))))
      (when-not (.exists (io/file file)) (bad (str "no such file as `" file "`")))
      (let [opts (driver/options (:checks? args) (:optimise? args) (:max-regs args))
            source (slurp file)]
        (try
          (do-command command file source opts args)
          (catch clojure.lang.ExceptionInfo e
            (case (:wolv (ex-data e))
              (:lex :parse :type) (complain (str file ":" (.getMessage e)))
              (:toolchain :out-of-registers) (complain (str "wolv: " (.getMessage e)))
              (throw e))))))))

(defn -main [& argv]
  (System/exit (wolv-main (vec argv))))

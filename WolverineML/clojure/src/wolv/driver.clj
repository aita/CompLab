(ns wolv.driver
  "The pipeline, and the toolchain around it.

      source ─lex─▶ tokens ─parse─▶ tree ─check─▶ typed tree ─lower─▶ CFG
             ─ssa─▶ SSA ─opt─▶ SSA ─select─▶ machine IR ─regalloc─▶ coloured
             ─emit─▶ ARMv8

  Assembling and linking is left to a cross `gcc`, and running to `qemu-aarch64`
  when the machine underneath is not itself an ARM.

  The pipeline is one list, named after what each pass leaves behind, and a dump
  is that list cut short: the order the passes run in is written down once, and
  `emit -s opt` cannot drift from `build`."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [wolv.allocator :as allocator]
            [wolv.astshow :as astshow]
            [wolv.dag :as dag]
            [wolv.emit :as emit]
            [wolv.ir :as ir]
            [wolv.lexer :as lexer]
            [wolv.lower :as lower]
            [wolv.mach :as mach]
            [wolv.opt :as opt]
            [wolv.outofssa :as outofssa]
            [wolv.parser :as parser]
            [wolv.registers :as reg]
            [wolv.select :as select]
            [wolv.ssa :as ssa]
            [wolv.typecheck :as typecheck])
  (:import (java.io File)
           (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)))

(def STAGES ["tokens" "ast" "ir" "ssa" "opt" "dag" "mach" "flat" "ra" "asm"])

(defn options [checks? optimise? max-regs]
  {:checks? checks? :optimise? optimise? :max-regs max-regs})

(defn default-options [] (options true true nil))

(defn- machine-of [opts]
  (if (:max-regs opts) (reg/limited (:max-regs opts)) (reg/whole-machine)))

(defn to-ir [source opts]
  (let [{:keys [program escapes]} (typecheck/check (parser/parse source))]
    (lower/lower program escapes (lower/options (:checks? opts)))))

(def ^:private PIPELINE
  "Each pass, under the name of the stage it produces.  Running one and then
  asking whether the caller wanted to stop there is the whole of `stage`."
  [["ir" (fn [m _] m)]
   ["ssa" (fn [m _] (ssa/construct-module m))]
   ["opt" (fn [m opts] (if (:optimise? opts) (opt/optimise m) m))]
   ;; The DAGs are a view of this, taken without changing it.
   ["dag" (fn [m _] (update m :funcs #(mapv ssa/split-critical-edges %)))]
   ["mach" (fn [m _] (mach/verify-module (select/select-module m)))]
   ["flat" (fn [m _] (outofssa/destruct-module m))]])

(defn compile-module
  "The module, and what the allocator decided about each of its functions —
  empty until the pipeline has run that far."
  ([source opts] (compile-module source opts "asm"))
  ([source opts upto]
   (loop [m (to-ir source opts) steps PIPELINE]
     (if (empty? steps)
       (allocator/allocate-module m (machine-of opts))
       (let [[name pass] (first steps)
             m (pass m opts)]
         (if (= upto name)
           [m {}]
           (recur m (rest steps))))))))

(defn compile-to-asm [source opts]
  (let [[m allocs] (compile-module source opts)]
    (emit/emit-module m allocs)))

(defn- show-dags [m]
  (str (str/join "\n\n"
                 (map (fn [f]
                        (str "fun " (:label f) "\n"
                             (str/join "\n" (map (fn [[label g]]
                                                   (str label ":\n" (dag/show g)))
                                                 (select/graphs f)))))
                      (:funcs m)))
       "\n"))

(defn stage
  "Run the pipeline as far as `name`, and show what it has by then."
  [source name opts]
  (cond
    (= name "tokens") (lexer/dump (lexer/lex source))
    (= name "ast") (let [{:keys [program escapes]} (typecheck/check (parser/parse source))]
                     (astshow/show-program program escapes))
    :else (let [[m allocs] (compile-module source opts name)]
            (cond
              (= name "dag") (show-dags m)
              (= name "asm") (emit/emit-module m allocs)
              :else (ir/show-module m allocs)))))

;; -- the toolchain -----------------------------------------------------------

(defn- toolchain-error [message]
  (throw (ex-info message {:wolv :toolchain})))

(defn- runtime-path
  "The runtime is found through the classpath, which is where this namespace was
  found too, so a compiled tree and a source one agree about where it is."
  []
  (let [here (io/file (.toURI (io/resource "wolv/ir.clj")))]
    (str (io/file (.getParentFile (.getParentFile (.getParentFile here)))
                  "runtime" "runtime.c"))))

(defn- on-arm? [] (contains? #{"aarch64" "arm64"} (System/getProperty "os.arch")))

(defn- which [name]
  (first (for [dir (str/split (or (System/getenv "PATH") "") #":")
               :let [path (io/file dir name)]
               :when (and (.exists path) (.canExecute path))]
           (str path))))

(defn cross-cc []
  (or (System/getenv "WOLV_CC")
      (some which ["aarch64-linux-gnu-gcc" "aarch64-linux-gnu-cc"
                   "aarch64-none-linux-gnu-gcc"])
      (and (on-arm?) (or (which "cc") (which "gcc")))
      (toolchain-error
       "no ARM compiler found; install aarch64-linux-gnu-gcc or set WOLV_CC")))

(defn emulator []
  (if (on-arm?)
    []
    (if-let [found (or (which "qemu-aarch64") (which "qemu-aarch64-static"))]
      [found]
      (toolchain-error "no qemu-aarch64 found, and this machine is not an ARM"))))

(defn toolchain-ready?
  "Whether an end-to-end test can run at all, so that one can say it is skipping."
  []
  (try (cross-cc) (emulator) true
       (catch clojure.lang.ExceptionInfo _ false)))

;; -- running a command -------------------------------------------------------

(defn- scratch-directory []
  (.toFile (Files/createTempDirectory "wolv" (into-array FileAttribute []))))

(defn- remove-directory [^File dir]
  (doseq [f (.listFiles dir)] (.delete ^File f))
  (.delete dir))

(defn- invoke
  "A command, its input, and the three things a run answers with."
  [command stdin-text ^File dir]
  (let [in (io/file dir "stdin")
        out (io/file dir "stdout")
        err (io/file dir "stderr")]
    (spit in stdin-text)
    (let [pb (doto (ProcessBuilder. ^java.util.List (vec command))
               (.redirectInput in)
               (.redirectOutput out)
               (.redirectError err))
          code (.waitFor (.start pb))]
      [code (slurp out) (slurp err)])))

(defn build [source out opts]
  (let [asm (compile-to-asm source opts)
        dir (scratch-directory)]
    (try
      (let [path (io/file dir "program.s")]
        (spit path asm)
        (let [[code _ stderr] (invoke [(cross-cc) "-static" "-O2" "-o" (str out)
                                       (str path) (runtime-path)]
                                      "" dir)]
          (when-not (zero? code)
            (toolchain-error (str "the assembler refused it:\n" stderr)))))
      (finally (remove-directory dir)))))

(defn run
  "The exit code, what it printed, and what it printed on the way out."
  ([source opts] (run source opts ""))
  ([source opts stdin]
   (let [dir (scratch-directory)]
     (try
       (let [binary (io/file dir "program")]
         (build source binary opts)
         (let [[code out err] (invoke (conj (emulator) (str binary)) stdin dir)]
           {:code code :stdout out :stderr err}))
       (finally (remove-directory dir))))))

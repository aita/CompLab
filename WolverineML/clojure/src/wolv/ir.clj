(ns wolv.ir
  "The three-address IR, and the control flow graph both IRs are written in.

  There are two instruction sets in this compiler.  This file has the first:
  three-address code over virtual registers, which is what lowering produces,
  what `ssa.clj` puts into SSA and what `opt.clj` rewrites.  The second is
  `:machine`, whose forms and meaning are `mach.clj`'s.

  An instruction is a map with an `:op`, and `:op` is what every pass over one
  dispatches on.  Nothing declares the set of them: adding an instruction is
  adding a keyword and the methods that answer for it, from anywhere, and no
  table anywhere else has to learn about it.

  What the two sets share is everything else — the registers, the blocks, the
  graph, the frame — so the passes that only care about the shape of a function
  work on either.  That is what `defs`, `uses`, `map-uses`, `with-def` and
  `effect?` are: an instruction says which register it writes and which it
  reads, and nothing outside this file asks what it is.

  A function is a value.  Every pass is `func -> func`, a block is rewritten by
  `update-in` rather than in place, and the allocator — which rewrites the
  function it is colouring, when it spills — answers with both."
  (:require [clojure.string :as str]))

;; -- the frame ---------------------------------------------------------------

(def WORD 8)

(def ARGUMENT-REGISTERS
  "How many arguments AAPCS64 passes in registers.  The rest go on the stack,
  and the frame layout knows where."
  8)

(defn slot-offset
  "Where a frame slot sits, relative to the frame pointer.

  Slot 0 of every nested function holds its static link, so a frame chain can be
  walked without knowing whose frame it is.  Negative slots are the arguments
  the caller had to pass on the stack: they are already in the frame, above the
  saved frame record, so nothing has to be copied for them."
  [slot]
  (if (neg? slot)
    (+ 16 (* WORD (- (- slot) 1)))
    (* (- WORD) (inc slot))))

;; -- the instructions --------------------------------------------------------

(defn i-const [dst value] {:op :const :dst dst :value value})
(defn i-str-const [dst symbol] {:op :str-const :dst dst :symbol symbol})
(defn i-move [dst src] {:op :move :dst dst :src src})
(defn i-bin [dst oper lhs rhs] {:op :bin :dst dst :oper oper :lhs lhs :rhs rhs})
(defn i-cmp [dst oper lhs rhs] {:op :cmp :dst dst :oper oper :lhs lhs :rhs rhs})
(defn i-load [dst base offset] {:op :load :dst dst :base base :offset offset})
(defn i-store [base offset src] {:op :store :base base :offset offset :src src})
(defn i-load-slot [dst slot] {:op :load-slot :dst dst :slot slot})
(defn i-store-slot [slot src] {:op :store-slot :slot slot :src src})
(defn i-frame-addr [dst] {:op :frame-addr :dst dst})
(defn i-call [dst callee args] {:op :call :dst dst :callee callee :args args})
(defn i-jmp [target] {:op :jmp :target target})
(defn i-cbr [test then els code] {:op :cbr :test test :then then :else els :code code})
(defn i-ret [value] {:op :ret :value value})
(defn i-machine [form dst srcs imm symbol effectful]
  {:op :machine :form form :dst dst :srcs srcs :imm imm
   :symbol symbol :effectful effectful})

;; -- what every instruction of either set can be asked ------------------------

(defmulti defs
  "The register it writes, or nil."
  :op)
(defmethod defs :default [_] nil)
(defmethod defs :const [i] (:dst i))
(defmethod defs :str-const [i] (:dst i))
(defmethod defs :move [i] (:dst i))
(defmethod defs :bin [i] (:dst i))
(defmethod defs :cmp [i] (:dst i))
(defmethod defs :load [i] (:dst i))
(defmethod defs :load-slot [i] (:dst i))
(defmethod defs :frame-addr [i] (:dst i))
(defmethod defs :call [i] (:dst i))
(defmethod defs :machine [i] (:dst i))

(defmulti uses
  "The registers it reads, in the order they are numbered in.  A phi's arguments
  are read on the edges, not where the phi stands, so a phi is not an
  instruction here at all."
  :op)
(defmethod uses :default [_] [])
(defmethod uses :move [i] [(:src i)])
(defmethod uses :bin [i] [(:lhs i) (:rhs i)])
(defmethod uses :cmp [i] [(:lhs i) (:rhs i)])
(defmethod uses :load [i] [(:base i)])
(defmethod uses :store [i] [(:base i) (:src i)])
(defmethod uses :store-slot [i] [(:src i)])
(defmethod uses :call [i] (vec (:args i)))
(defmethod uses :machine [i] (vec (:srcs i)))
(defmethod uses :cbr [i] (if (= (:code i) "") [(:test i)] []))
(defmethod uses :ret [i] (if (:value i) [(:value i)] []))

(defmulti map-uses
  "The same instruction with the registers it reads renamed."
  (fn [i _f] (:op i)))
(defmethod map-uses :default [i _] i)
(defmethod map-uses :move [i f] (update i :src f))
(defmethod map-uses :bin [i f] (-> i (update :lhs f) (update :rhs f)))
(defmethod map-uses :cmp [i f] (-> i (update :lhs f) (update :rhs f)))
(defmethod map-uses :load [i f] (update i :base f))
(defmethod map-uses :store [i f] (-> i (update :base f) (update :src f)))
(defmethod map-uses :store-slot [i f] (update i :src f))
(defmethod map-uses :call [i f] (update i :args #(mapv f %)))
(defmethod map-uses :machine [i f] (update i :srcs #(mapv f %)))
(defmethod map-uses :cbr [i f] (if (= (:code i) "") (update i :test f) i))
(defmethod map-uses :ret [i f] (if (:value i) (update i :value f) i))

(defn with-def
  "The same instruction, writing `r` instead.  Only asked of one that writes."
  [i r]
  (assoc i :dst r))

(defmulti effect?
  "True when it has to be kept even if its result is dead."
  :op)
(defmethod effect? :default [_] false)
(defmethod effect? :store [_] true)
(defmethod effect? :store-slot [_] true)
(defmethod effect? :call [_] true)
(defmethod effect? :jmp [_] true)
(defmethod effect? :cbr [_] true)
(defmethod effect? :ret [_] true)
(defmethod effect? :machine [i] (:effectful i))

(defmulti rename-target
  "The same terminator, with one of its targets renamed."
  (fn [i _old _fresh] (:op i)))
(defmethod rename-target :default [i _ _] i)
(defmethod rename-target :jmp [i old fresh]
  (update i :target #(if (= % old) fresh %)))
(defmethod rename-target :cbr [i old fresh]
  (let [swap #(if (= % old) fresh %)]
    (-> i (update :then swap) (update :else swap))))

;; -- phis --------------------------------------------------------------------

;; `:args` is a vector of `[pred reg]`, and a vector rather than a map because
;; the order they were placed in is the order a dump has to print them in.
(defn phi [dst args] {:dst dst :args (vec args)})

(defn phi-arg [p pred] (first (filter #(= (first %) pred) (:args p))))

(defn phi-set-arg
  "Keeps an argument where it was, and appends a new one at the end."
  [pred r p]
  (if (phi-arg p pred)
    (update p :args (fn [as] (mapv (fn [a] (if (= (first a) pred) [pred r] a)) as)))
    (update p :args conj [pred r])))

(defn phi-remove-arg
  "The argument that came in through `pred`, and the phi without it."
  [pred p]
  (when-let [found (phi-arg p pred)]
    [(second found) (update p :args (fn [as] (filterv #(not= (first %) pred) as)))]))

(defn phi-preds [p] (mapv first (:args p)))

;; -- the graph ---------------------------------------------------------------

(defn new-func [label name depth]
  {:label label :name name :params [] :depth depth :entry "entry"
   :blocks {} :order [] :nregs 0 :nslots 0 :link-slot -1})

(defn new-module [] {:funcs [] :strings []})

(defn allocation [colours saved spilled]
  {:colours colours :saved saved :spilled spilled})

(def unallocated (allocation {} [] {}))

(defn new-reg [f] [(update f :nregs inc) (:nregs f)])
(defn new-slot [f] [(update f :nslots inc) (:nslots f)])

(defn block-of [f label]
  (or (get (:blocks f) label)
      (throw (ex-info (str "no block " label " in " (:name f)) {}))))

(defn add-block [f label]
  (when (get (:blocks f) label)
    (throw (ex-info (str "block " label " already exists") {})))
  (-> f
      (assoc-in [:blocks label] {:label label :phis [] :instrs [] :preds []})
      (update :order conj label)))

(defn blocks
  "Every block, in the order they were made."
  [f]
  (map #(block-of f %) (:order f)))

(defn instrs [b] (:instrs b))

(defn emit [f label i] (update-in f [:blocks label :instrs] conj i))
(defn set-instrs [f label is] (assoc-in f [:blocks label :instrs] (vec is)))
(defn set-phis [f label ps] (assoc-in f [:blocks label :phis] (vec ps)))

(defn map-blocks
  "`g` over every block of `f`, answering with the function it made."
  [f g]
  (reduce (fn [f label] (update-in f [:blocks label] g)) f (:order f)))

(defn terminator [b]
  (let [final (last (:instrs b))]
    (when-not final
      (throw (ex-info (str "block " (:label b) " is unterminated") {})))
    (when-not (contains? #{:jmp :cbr :ret} (:op final))
      (throw (ex-info (str "block " (:label b) " falls through") {})))
    final))

(defn succs [b]
  (let [t (terminator b)]
    (case (:op t)
      :jmp [(:target t)]
      :cbr (if (= (:then t) (:else t)) [(:then t)] [(:then t) (:else t)])
      [])))

;; -- rewiring ----------------------------------------------------------------

(defn recompute-preds [f]
  (let [preds (reduce (fn [m b]
                        ;; Built by prepending and reversed once, because the
                        ;; order predecessors are listed in is what a dump
                        ;; prints.
                        (reduce (fn [m s] (update m s conj (:label b))) m (succs b)))
                      (zipmap (:order f) (repeat ()))
                      (blocks f))]
    (reduce (fn [f label]
              (assoc-in f [:blocks label :preds] (vec (reverse (get preds label)))))
            f (:order f))))

(defn reachable [f]
  (loop [seen #{} stack [(:entry f)]]
    (if-let [label (first stack)]
      (if (seen label)
        (recur seen (rest stack))
        (recur (conj seen label) (concat (succs (block-of f label)) (rest stack))))
      seen)))

(defn drop-unreachable [f]
  (let [live (reachable f)
        kept (filterv live (:order f))]
    (-> f
        (assoc :order kept)
        (assoc :blocks (select-keys (:blocks f) kept))
        (map-blocks (fn [b]
                      (update b :phis
                              (fn [ps]
                                (mapv (fn [p]
                                        (update p :args
                                                #(filterv (fn [a] (live (first a))) %)))
                                      ps)))))
        recompute-preds)))

(defn rpo
  "Reverse post-order, which is the order every dataflow pass walks in."
  [f]
  (letfn [(go [[seen post] label]
            (if (seen label)
              [seen post]
              (let [[seen post] (reduce go [(conj seen label) post]
                                        (succs (block-of f label)))]
                [seen (conj post label)])))]
    (vec (reverse (second (go [#{} []] (:entry f)))))))

;; -- printing ----------------------------------------------------------------

(defn reg-name [colours r]
  (if-let [c (get colours r)] (str "%" r ":" c) (str "%" r)))

(defn naming [colours] (fn [r] (reg-name colours r)))

(defmulti show-instr (fn [i _name] (:op i)))

(defmethod show-instr :const [i nm] (str (nm (:dst i)) " = " (:value i)))
(defmethod show-instr :str-const [i nm] (str (nm (:dst i)) " = &" (:symbol i)))
(defmethod show-instr :move [i nm] (str (nm (:dst i)) " = " (nm (:src i))))
(defmethod show-instr :bin [i nm]
  (str (nm (:dst i)) " = " (nm (:lhs i)) " " (:oper i) " " (nm (:rhs i))))
(defmethod show-instr :cmp [i nm]
  (str (nm (:dst i)) " = " (nm (:lhs i)) " " (:oper i) " " (nm (:rhs i))))
(defmethod show-instr :load [i nm]
  (str (nm (:dst i)) " = [" (nm (:base i)) " + " (:offset i) "]"))
(defmethod show-instr :store [i nm]
  (str "[" (nm (:base i)) " + " (:offset i) "] = " (nm (:src i))))
(defmethod show-instr :load-slot [i nm] (str (nm (:dst i)) " = slot" (:slot i)))
(defmethod show-instr :store-slot [i nm] (str "slot" (:slot i) " = " (nm (:src i))))
(defmethod show-instr :frame-addr [i nm] (str (nm (:dst i)) " = frame"))
(defmethod show-instr :call [i nm]
  (let [call (str (:callee i) "(" (str/join ", " (map nm (:args i))) ")")]
    (if (:dst i) (str (nm (:dst i)) " = " call) call)))
(defmethod show-instr :jmp [i _] (str "jmp " (:target i)))
(defmethod show-instr :cbr [i nm]
  (let [test (if (= (:code i) "") (str (nm (:test i)) " ?") (str (:code i) "?"))]
    (str "br " test " " (:then i) " : " (:else i))))
(defmethod show-instr :ret [i nm]
  (if (:value i) (str "ret " (nm (:value i))) "ret"))
(defmethod show-instr :machine [i nm]
  (let [operands (concat (map nm (:srcs i))
                         (cond
                           (not= (:symbol i) "") [(:symbol i)]
                           (or (not (zero? (:imm i))) (= (:form i) "const"))
                           [(str "#" (:imm i))]
                           :else []))
        written (str/trimr (str (:form i) " " (str/join ", " operands)))]
    (if (:dst i) (str (nm (:dst i)) " = " written) written)))

(defn show-phi [nm p]
  (str (nm (:dst p)) " = phi ["
       (str/join ", " (map (fn [[pred r]] (str pred ": " (nm r))) (:args p)))
       "]"))

(defn show-func
  ([f] (show-func f unallocated))
  ([f alloc]
   (let [nm (naming (:colours alloc))]
     (str/join
      "\n"
      (cons (str "fun " (:label f) "(" (str/join ", " (map nm (:params f))) ")"
                 "  ; depth " (:depth f) ", " (:nslots f) " slots")
            (mapcat (fn [b]
                      (concat [(str (:label b) ":"
                                    (if (seq (:preds b))
                                      (str "  ; preds: " (str/join ", " (:preds b)))
                                      ""))]
                              (map #(str "    " (show-phi nm %)) (:phis b))
                              (map #(str "    " (show-instr % nm)) (instrs b))))
                    (blocks f)))))))

(defn show-module
  ([m] (show-module m {}))
  ([m allocs]
   (let [parts (map (fn [f] (show-func f (get allocs (:label f) unallocated))) (:funcs m))
         with-strings (if (empty? (:strings m))
                        parts
                        (concat parts
                                [(str/join "\n"
                                           (map (fn [s]
                                                  (str (:symbol s) ": \"" (:text s) "\""))
                                                (:strings m)))]))]
     (str (str/join "\n\n" with-strings) "\n"))))

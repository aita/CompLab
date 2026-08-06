(ns wolv.emit
  "ARMv8 assembly, in AAPCS64.

  The frame is the ordinary one.  `x29` points at the saved frame record, the
  slots an escaping variable or a spill lives in are below it, the callee-saved
  registers this function actually used are below those, and outgoing stack
  arguments sit at the bottom, at `sp`, where the callee expects them.

      x29 -> | saved x29, x30 |
             | slot 0         |   x29 - 8      also where a static link points
             | slot 1         |   x29 - 16
             | ...            |
             | saved x19...   |
      sp  -> | outgoing args  |

  The allocator this tree keeps leaves SSA before it colours, so a phi never
  reaches here.  The copies a phi stood for are already instructions, and the
  only parallel copies left are the ones the ABI makes at a call and in the
  prologue — which are still parallel, and still go through `sequentialize`:
  when they form a cycle it borrows a register the function never used, and when
  there is none it swaps the two ends with three `eor`s, so no register has to
  be reserved for it.

  An emitter answers with the lines it wrote, so `out` is a vector that a step
  appends to and nothing here writes to a port."
  (:require [clojure.string :as str]
            [wolv.copies :as copies]
            [wolv.ir :as ir]
            [wolv.mach :as mach]
            [wolv.registers :as reg]))

(def ^:private UNSCALED {"ldr" "ldur" "str" "stur"})

(def ^:private SPARE
  "The one register kept back.  A frame big enough to put a slot out of reach of
  `ldur` is only discovered after allocation has added its spill slots, so the
  address has to be computed somewhere the allocator does not know about."
  (first reg/SCRATCH))

(def ^:private PROLOGUE-TEMP
  "Nothing of ours is live at the top of the prologue except the incoming
  arguments, so a caller-saved register that is not one of them is free there."
  9)

(def ^:dynamic *borrow-nothing*
  "Shut off, the copies swap instead — which is the path a test would never
  reach on its own, because there is nearly always something to borrow."
  false)

;; -- the frame ---------------------------------------------------------------

(defn- frame-of [f alloc]
  (let [stack-args (reduce (fn [most i]
                             (if (= (:op i) :call)
                               (max most (- (count (:args i)) (count reg/ARGUMENT-REGS)))
                               most))
                           0 (for [b (ir/blocks f) i (ir/instrs b)] i))
        saved (:saved alloc)
        raw (* ir/WORD (+ (:nslots f) (count saved) (max stack-args 0)))]
    {:slots (:nslots f) :saved saved :stack-args (max stack-args 0)
     :size (bit-and (+ raw 15) (bit-not 15))}))

(defn- saved-offset [fr index] (* (- ir/WORD) (+ (:slots fr) index 1)))

;; -- one function ------------------------------------------------------------

(defn- new-emitter [f alloc]
  ;; `:read` is what the prologue asks before moving an argument into place: a
  ;; parameter nothing reads needs no `mov`.  `:taken` is every colour the
  ;; function gave to a value, which is what says a register is free to borrow.
  {:func f :alloc alloc :frame (frame-of f alloc) :out []
   :epilogue (str ".Lepi_" (:label f))
   :read (into #{} (concat (for [b (ir/blocks f) p (:phis b) [_ r] (:args p)] r)
                           (for [b (ir/blocks f) i (ir/instrs b) r (ir/uses i)] r)))
   :taken (into #{} (vals (:colours alloc)))})

(defn- out [e text] (update e :out conj text))
(defn- line [e text] (out e (str "\t" text)))
(defn- label-line [e text] (out e (str text ":")))

(defn- colour-of [e r]
  (or (get (:colours (:alloc e)) r)
      (throw (ex-info (str "%" r " was never coloured") {}))))

(defn- mov [e dst src]
  (if (= dst src) e (line e (str "mov x" dst ", x" src))))

(defn- immediate
  "A 64-bit constant, in as many `movz`/`movk` as its non-zero halves need."
  [e dst value]
  (let [word (bit-and value -1)]
    (if (zero? word)
      (line e (str "mov x" dst ", #0"))
      (first
       (reduce (fn [[e first?] [shift i]]
                 (let [chunk (bit-and (unsigned-bit-shift-right word shift) 0xFFFF)]
                   (if (zero? chunk)
                     [e first?]
                     [(line e (str (if first? "movz" "movk") " x" dst ", #" chunk
                                   (if (zero? i) "" (str ", lsl #" (* i 16)))))
                      false])))
               [e true] (map vector [0 16 32 48] (range)))))))

(defn- access
  "`ldr`/`str`, in whichever addressing mode reaches this far."
  [e op r base offset]
  (let [where (if (= base 31) "sp" (str "x" base))]
    (cond
      (and (<= 0 offset 32760) (zero? (mod offset ir/WORD)))
      (line e (str op " x" r ", [" where ", #" offset "]"))

      (<= -256 offset 255)
      (line e (str (UNSCALED op) " x" r ", [" where ", #" offset "]"))

      :else
      (-> e
          (immediate SPARE offset)
          (line (str op " x" r ", [" where ", x" SPARE "]"))))))

;; -- parallel copies ---------------------------------------------------------

(defn- borrowed
  "A register free to clobber here, if the function left one over.

  A caller-saved register this function never gave to a value holds nothing of
  ours anywhere, and one that this copy neither reads nor writes holds nothing
  of the copy's either.  With no such register the copies swap instead, which
  needs no scratch at all."
  [e moves]
  (let [touched (into #{} (concat (map first moves) (map second moves)))]
    (when-not *borrow-nothing*
      (first (remove #(or (contains? (:taken e) %) (contains? touched %))
                     reg/CALLER-SAVED)))))

(defn- parallel [e moves]
  (reduce (fn [e step]
            (if (copies/mov? step)
              (mov e (:dst step) (:src step))
              (let [a (:a step) b (:b step)]
                (-> e
                    (line (str "eor x" a ", x" a ", x" b))
                    (line (str "eor x" b ", x" a ", x" b))
                    (line (str "eor x" a ", x" a ", x" b))))))
          e (copies/sequentialize moves (borrowed e moves))))

;; -- one instruction ---------------------------------------------------------

(defn- fill
  "Every occurrence of `from` in `text`, replaced by `to`."
  [text from to]
  (str/replace text from to))

(defn- machine [e i]
  (let [{:keys [form dst imm symbol]} i
        coloured (mapv #(colour-of e %) (:srcs i))]
    (case form
      "const" (immediate e (colour-of e dst) imm)
      "adr" (let [d (colour-of e dst)]
              (-> e
                  (line (str "adrp x" d ", " symbol))
                  (line (str "add x" d ", x" d ", :lo12:" symbol))))
      "ldr" (access e "ldr" (colour-of e dst) (first coloured) imm)
      "str" (access e "str" (second coloured) (first coloured) imm)
      ;; Everything else is the table's line with its holes filled in.
      (let [holes (concat (map-indexed (fn [n c] [(str "{s" n "}") (str "x" c)]) coloured)
                          [["{imm}" (str imm)]
                           ["{sym}" symbol]
                           ["{d}" (if dst (str "x" (colour-of e dst)) "")]])]
        (line e (reduce (fn [text [from to]] (fill text from to))
                        (mach/form-of form) holes))))))

(defn- call [e dst callee args]
  (let [in-registers (mapv vector reg/ARGUMENT-REGS (map #(colour-of e %) args))
        extra (drop (count reg/ARGUMENT-REGS) args)
        e (reduce (fn [e [i a]] (access e "str" (colour-of e a) 31 (* ir/WORD i)))
                  e (map-indexed (fn [i a] [i a]) extra))
        e (parallel e in-registers)
        e (line e (str "bl " callee))]
    (if dst (mov e (colour-of e dst) (first reg/ARGUMENT-REGS)) e)))

(defmulti ^:private instruction (fn [_e i] (:op i)))

(defmethod instruction :default [_ _]
  (throw (ex-info "cannot emit this instruction" {})))

(defmethod instruction :machine [e i] (machine e i))
(defmethod instruction :move [e {:keys [dst src]}]
  (mov e (colour-of e dst) (colour-of e src)))
(defmethod instruction :load-slot [e {:keys [dst slot]}]
  (access e "ldr" (colour-of e dst) 29 (ir/slot-offset slot)))
(defmethod instruction :store-slot [e {:keys [slot src]}]
  (access e "str" (colour-of e src) 29 (ir/slot-offset slot)))
(defmethod instruction :frame-addr [e {:keys [dst]}] (mov e (colour-of e dst) 29))
(defmethod instruction :call [e {:keys [dst callee args]}] (call e dst callee args))

;; -- whole functions ---------------------------------------------------------

(defn- edge
  "The copies a phi stands for, made real on this edge.  The allocator this tree
  keeps left SSA already, so this is only ever asked of a block with no phis."
  [e source target]
  (let [phis (:phis (ir/block-of (:func e) target))]
    (if (empty? phis)
      e
      (parallel e (mapv (fn [p]
                          [(colour-of e (:dst p))
                           (colour-of e (second (ir/phi-arg p source)))])
                        phis)))))

(defn- terminator [e b next-label]
  (let [where (fn [name] (str ".L" (:label (:func e)) "_" name))
        fall-through (fn [e els]
                       (if (= els next-label) e (line e (str "b " (where els)))))
        t (ir/terminator b)]
    (case (:op t)
      :jmp (-> e (edge (:label b) (:target t)) (fall-through (:target t)))

      :cbr
      (if-not (= (:code t) "")
        ;; The flags are already set, so the branch reads them and no register.
        (if (= (:then t) next-label)
          (line e (str "b." (mach/opposite-of (:code t)) " " (where (:else t))))
          (-> e
              (line (str "b." (:code t) " " (where (:then t))))
              (fall-through (:else t))))
        (if (= (:then t) next-label)
          (line e (str "cbz x" (colour-of e (:test t)) ", " (where (:else t))))
          (-> e
              (line (str "cbnz x" (colour-of e (:test t)) ", " (where (:then t))))
              (fall-through (:else t)))))

      :ret
      (let [e (if (:value t) (mov e (first reg/ARGUMENT-REGS) (colour-of e (:value t))) e)]
        ;; The epilogue follows the last block, so the last `ret` needs no branch.
        (if next-label (line e (str "b " (:epilogue e))) e)))))

(defn- block [e b next-label]
  (-> (reduce instruction e (butlast (ir/instrs b)))
      (terminator b next-label)))

(defn- prologue [e]
  (let [fr (:frame e)
        e (-> e
              (line "stp x29, x30, [sp, #-16]!")
              (line "mov x29, sp"))
        e (if (zero? (:size fr))
            e
            (if (<= (:size fr) 4095)
              (line e (str "sub sp, sp, #" (:size fr)))
              (-> e
                  (immediate PROLOGUE-TEMP (:size fr))
                  (line (str "sub sp, sp, x" PROLOGUE-TEMP)))))
        e (reduce (fn [e [i r]] (access e "str" r 29 (saved-offset fr i)))
                  e (map-indexed (fn [i r] [i r]) (:saved fr)))]
    (parallel e (vec (keep (fn [[p r]] (when (contains? (:read e) p) [(colour-of e p) r]))
                           (map vector (:params (:func e)) reg/ARGUMENT-REGS))))))

(defn- restore [e]
  (reduce (fn [e [i r]] (access e "ldr" r 29 (saved-offset (:frame e) i)))
          e (map-indexed (fn [i r] [i r]) (:saved (:frame e)))))

(defn emit-func [f alloc]
  (let [order (:order f)
        e (-> (new-emitter f alloc)
              (out (str "\t.globl " (:label f)))
              (out (str "\t.type " (:label f) ", %function"))
              (label-line (:label f))
              prologue)
        e (reduce (fn [e i]
                    (let [name (nth order i)]
                      (-> e
                          (label-line (str ".L" (:label f) "_" name))
                          (block (ir/block-of f name)
                                 (when (< (inc i) (count order)) (nth order (inc i)))))))
                  e (range (count order)))]
    (:out (-> e
              (label-line (:epilogue e))
              restore
              (line "mov sp, x29")
              (line "ldp x29, x30, [sp], #16")
              (line "ret")
              (out (str "\t.size " (:label f) ", .-" (:label f)))))))

;; -- modules -----------------------------------------------------------------

(defn escape
  "One character of a literal is one byte; write the ones `.ascii` cannot."
  [text]
  (apply str
         (map (fn [c]
                (let [ch (int c)]
                  (cond
                    (= ch 0x22) "\\\""
                    (= ch 0x5C) "\\\\"
                    (and (<= 0x20 ch) (< ch 0x7F)) (str c)
                    :else (str "\\" (let [octal (Integer/toOctalString ch)]
                                      (str (apply str (repeat (max 0 (- 3 (count octal))) "0"))
                                           octal))))))
              text)))

(defn emit-module [m allocs]
  (let [out (concat
             ["\t.text"]
             (mapcat (fn [f] (concat (emit-func f (get allocs (:label f))) [""])) (:funcs m))
             (if (empty? (:strings m))
               []
               (cons "\t.section .rodata"
                     (mapcat (fn [s]
                               ["\t.p2align 3"
                                (str (:symbol s) ":")
                                (str "\t.quad " (count (:text s)))
                                (str "\t.ascii \"" (escape (:text s)) "\"")
                                "\t.byte 0"])
                             (:strings m))))
             ["\t.section .note.GNU-stack,\"\",%progbits"])]
    (str (str/join "\n" out) "\n")))

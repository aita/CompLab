(ns wolv.hints
  "Which colour a value would like, which is the calling convention asking.

  The allocator does not have to satisfy these — a preference is dropped the
  moment it clashes with something the colouring actually requires — but taking
  one when it is free is what stops the emitter having to move a value into `x2`
  on the way into a call, or out of `x0` on the way back from one."
  (:require [wolv.ir :as ir]
            [wolv.registers :as reg]))

(defn preferences
  "The register each value is about to be wanted in, where there is one."
  [f]
  (reduce
   (fn [wanted i]
     (case (:op i)
       :call (let [wanted (into wanted (map vector (:args i) reg/ARGUMENT-REGS))]
               (if (:dst i) (assoc wanted (:dst i) (first reg/ARGUMENT-REGS)) wanted))
       :ret (if (:value i) (assoc wanted (:value i) (first reg/ARGUMENT-REGS)) wanted)
       wanted))
   (into {} (map vector (:params f) reg/ARGUMENT-REGS))
   (for [b (ir/blocks f) i (ir/instrs b)] i)))

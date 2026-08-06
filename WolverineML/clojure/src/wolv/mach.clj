(ns wolv.mach
  "The machine IR: what instruction selection replaces the arithmetic with.

  One instruction, because on this machine an instruction is a form, a register
  it writes and some it reads — `:machine`.  The form names an entry in the
  table below, and the table is the whole instruction set the compiler can
  choose from.

  The machine IR is that plus the part of `ir.clj` that was already
  machine-level: a call, a move, a frame slot, a phi and the three terminators.
  What it may no longer contain is the arithmetic — `:const`, `:bin`, `:cmp`,
  `:load`, `:store`, `:str-const` — and `verify` is what says so, because a
  compiler that quietly kept an abstract instruction until the emitter would
  only find out there.

  Four forms are not one instruction each, and the emitter expands them:

      const   a constant, which is a `mov` or up to four `movz`/`movk`
      adr     the address of a string, which is `adrp` and an `add`
      ldr     a load, whose addressing mode depends on how far the offset reaches
      str     a store, likewise"
  (:require [wolv.ir :as ir]))

(def FORMS
  "How each form is written down, once the registers have their colours.  `d` is
  the register written and `s0`, `s1`, `s2` the ones read."
  {"add" "add {d}, {s0}, {s1}"
   "addi" "add {d}, {s0}, #{imm}"
   "adds" "add {d}, {s0}, {s1}, lsl #{imm}"
   "sub" "sub {d}, {s0}, {s1}"
   "subi" "sub {d}, {s0}, #{imm}"
   "subs" "sub {d}, {s0}, {s1}, lsl #{imm}"
   "mul" "mul {d}, {s0}, {s1}"
   "madd" "madd {d}, {s0}, {s1}, {s2}"
   "msub" "msub {d}, {s0}, {s1}, {s2}"
   "sdiv" "sdiv {d}, {s0}, {s1}"
   "and" "and {d}, {s0}, {s1}"
   "orr" "orr {d}, {s0}, {s1}"
   "eor" "eor {d}, {s0}, {s1}"
   "eori" "eor {d}, {s0}, #{imm}"
   "lsl" "lsl {d}, {s0}, {s1}"
   "lsli" "lsl {d}, {s0}, #{imm}"
   "asr" "asr {d}, {s0}, {s1}"
   "asri" "asr {d}, {s0}, #{imm}"
   "cmp" "cmp {s0}, {s1}"
   "cmpi" "cmp {s0}, #{imm}"
   "cset" "cset {d}, {sym}"})

(def CONDITION
  "Which condition code each comparison sets."
  {"=" "eq" "<>" "ne" "<" "lt" "<=" "le" ">" "gt" ">=" "ge" "u<" "lo" "u>=" "hs"})

(def OPPOSITE
  "And which one says the opposite — the emitter needs it when the branch it is
  writing falls through to the block the comparison was true for."
  {"eq" "ne" "ne" "eq" "lt" "ge" "ge" "lt"
   "gt" "le" "le" "gt" "lo" "hs" "hs" "lo"})

(def EXPANDED
  "The ones the emitter writes itself, because they are not one instruction."
  #{"const" "adr" "ldr" "str"})

(defn form-of [form] (get FORMS form))
(defn condition-of [op] (get CONDITION op))
(defn opposite-of [code] (get OPPOSITE code))

(def ^:private abstract? #{:const :str-const :bin :cmp :load :store})

(defn verify
  "Insist that selection left nothing of the three-address IR behind."
  [f]
  (doseq [b (ir/blocks f)
          i (ir/instrs b)]
    (when (abstract? (:op i))
      (throw (ex-info (str "an abstract instruction survived selection in "
                           (:name f) ":" (:label b)) {})))
    (when (and (= (:op i) :machine)
               (not (contains? FORMS (:form i)))
               (not (contains? EXPANDED (:form i))))
      (throw (ex-info (str "no such instruction as `" (:form i) "`") {}))))
  f)

(defn verify-module [m] (doseq [f (:funcs m)] (verify f)) m)

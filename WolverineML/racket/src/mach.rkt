#lang racket/base

;; The machine IR: what instruction selection replaces the arithmetic with.
;;
;; One instruction struct, because on this machine an instruction is a form, a
;; register it writes and some it reads — `ir:i:machine`.  The form names an
;; entry in the table below, and the table is the whole instruction set the
;; compiler can choose from.
;;
;; The machine IR is that plus the part of `ir.rkt` that was already
;; machine-level: a call, a move, a frame slot, a phi and the three terminators.
;; What it may no longer contain is the arithmetic — `i:const`, `i:bin`, `i:cmp`,
;; `i:load`, `i:store`, `i:str-const` — and `verify` is what says so, because a
;; compiler that quietly kept an abstract instruction until the emitter would
;; only find out there.
;;
;; Four forms are not one instruction each, and the emitter expands them:
;;
;;     const   a constant, which is a `mov` or up to four `movz`/`movk`
;;     adr     the address of a string, which is `adrp` and an `add`
;;     ldr     a load, whose addressing mode depends on how far the offset reaches
;;     str     a store, likewise

(require racket/list
         (prefix-in ir: "ir.rkt"))

(provide FORMS CONDITION OPPOSITE EXPANDED
         form-of condition-of opposite-of expanded? verify verify-module)

;; How each form is written down, once the registers have their colours.  `d` is
;; the register written and `s0`, `s1`, `s2` the ones read.
(define FORMS
  '(("add" . "add {d}, {s0}, {s1}")
    ("addi" . "add {d}, {s0}, #{imm}")
    ("adds" . "add {d}, {s0}, {s1}, lsl #{imm}")
    ("sub" . "sub {d}, {s0}, {s1}")
    ("subi" . "sub {d}, {s0}, #{imm}")
    ("subs" . "sub {d}, {s0}, {s1}, lsl #{imm}")
    ("mul" . "mul {d}, {s0}, {s1}")
    ("madd" . "madd {d}, {s0}, {s1}, {s2}")
    ("msub" . "msub {d}, {s0}, {s1}, {s2}")
    ("sdiv" . "sdiv {d}, {s0}, {s1}")
    ("and" . "and {d}, {s0}, {s1}")
    ("orr" . "orr {d}, {s0}, {s1}")
    ("eor" . "eor {d}, {s0}, {s1}")
    ("eori" . "eor {d}, {s0}, #{imm}")
    ("lsl" . "lsl {d}, {s0}, {s1}")
    ("lsli" . "lsl {d}, {s0}, #{imm}")
    ("asr" . "asr {d}, {s0}, {s1}")
    ("asri" . "asr {d}, {s0}, #{imm}")
    ("cmp" . "cmp {s0}, {s1}")
    ("cmpi" . "cmp {s0}, #{imm}")
    ("cset" . "cset {d}, {sym}")))

;; Which condition code each comparison sets, and which one says the opposite —
;; the emitter needs the opposite when the branch it is writing falls through to
;; the block the comparison was true for.
(define CONDITION
  '(("=" . "eq") ("<>" . "ne") ("<" . "lt") ("<=" . "le")
    (">" . "gt") (">=" . "ge") ("u<" . "lo") ("u>=" . "hs")))

(define OPPOSITE
  '(("eq" . "ne") ("ne" . "eq") ("lt" . "ge") ("ge" . "lt")
    ("gt" . "le") ("le" . "gt") ("lo" . "hs") ("hs" . "lo")))

;; The ones the emitter writes itself, because they are not one instruction.
(define EXPANDED '("const" "adr" "ldr" "str"))

(define (form-of form) (cdr (assoc form FORMS)))
(define (condition-of op) (cdr (assoc op CONDITION)))
(define (opposite-of code) (cdr (assoc code OPPOSITE)))
(define (expanded? form) (and (member form EXPANDED) #t))

;; Insist that selection left nothing of the three-address IR behind.
(define (abstract? i)
  (or (ir:i:const? i) (ir:i:str-const? i) (ir:i:bin? i)
      (ir:i:cmp? i) (ir:i:load? i) (ir:i:store? i)))

(define (verify f)
  (for* ([b (in-list (ir:walk f))] [i (in-list (ir:instrs b))])
    (when (abstract? i)
      (error 'mach "an abstract instruction survived selection in ~a:~a"
             (ir:func-name f) (ir:block-label b)))
    (when (and (ir:i:machine? i)
               (not (assoc (ir:i:machine-form i) FORMS))
               (not (expanded? (ir:i:machine-form i))))
      (error 'mach "no such instruction as `~a`" (ir:i:machine-form i)))))

(define (verify-module m) (for ([f (in-list (ir:module*-funcs m))]) (verify f)))

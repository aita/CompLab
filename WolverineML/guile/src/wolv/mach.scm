;;; The machine IR: what instruction selection replaces the arithmetic with.
;;;
;;; One instruction class, because on this machine an instruction is a form, a
;;; register it writes and some it reads — `<i-machine>`.  The form names an
;;; entry in the table below, and the table is the whole instruction set the
;;; compiler can choose from.
;;;
;;; The machine IR is that plus the part of `ir.scm` that was already
;;; machine-level: a call, a move, a frame slot, a phi and the three
;;; terminators.  What it may no longer contain is the arithmetic —
;;; `<i-const>`, `<i-bin>`, `<i-cmp>`, `<i-load>`, `<i-store>`,
;;; `<i-str-const>` — and `verify` is what says so, because a compiler that
;;; quietly kept an abstract instruction until the emitter would only find out
;;; there.
;;;
;;; Four forms are not one instruction each, and the emitter expands them:
;;;
;;;     const   a constant, which is a `mov` or up to four `movz`/`movk`
;;;     adr     the address of a string, which is `adrp` and an `add`
;;;     ldr     a load, whose addressing mode depends on how far the offset goes
;;;     str     a store, likewise

(define-module (wolv mach)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (wolv ir)
  #:export (FORMS CONDITION OPPOSITE EXPANDED
            form-of condition-of opposite-of expanded? known-form? verify verify-module))

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
(define (known-form? form) (and (assoc form FORMS) #t))

;; Insist that selection left nothing of the three-address IR behind.
(define (abstract? i)
  (or (is-a? i <i-const>) (is-a? i <i-str-const>) (is-a? i <i-arith>)
      (is-a? i <i-load>) (is-a? i <i-store>)))

(define (verify f)
  (for-each
   (lambda (b)
     (for-each
      (lambda (i)
        (when (abstract? i)
          (error (format #f "an abstract instruction survived selection in ~a:~a"
                         (func-name f) (block-label b))))
        (when (and (is-a? i <i-machine>)
                   (not (known-form? (i-machine-form i)))
                   (not (expanded? (i-machine-form i))))
          (error (format #f "no such instruction as `~a`" (i-machine-form i)))))
      (instrs b)))
   (walk f)))

(define (verify-module m) (for-each verify (module-funcs m)))

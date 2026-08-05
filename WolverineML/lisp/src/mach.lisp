;;;; The machine IR: what instruction selection replaces the arithmetic with.
;;;;
;;;; One class, because on this machine an instruction is a form, a register it
;;;; writes and some it reads.  The form names an entry in the table below, and
;;;; the table is the whole instruction set the compiler can choose from.
;;;;
;;;; The machine IR is this plus the part of `ir` that was already
;;;; machine-level: a call, a move, a frame slot, a phi and the three
;;;; terminators.  What it may no longer contain is the arithmetic --
;;;; `i-const`, `i-bin`, `i-cmp`, `i-load`, `i-store`, `i-str-const` -- and
;;;; `verify` is what says so, because a compiler that quietly kept an abstract
;;;; instruction until the emitter would only find out there.
;;;;
;;;; Four forms are not one instruction each, and the emitter expands them:
;;;;
;;;;     const   a constant, which is a `mov` or up to four `movz`/`movk`
;;;;     adr     the address of a string, which is `adrp` and an `add`
;;;;     ldr     a load, whose addressing mode depends on how far the offset reaches
;;;;     str     a store, likewise

(defpackage #:wolv.mach
  (:use #:cl)
  ;; The two slots this instruction shares with the abstract ones are the same
  ;; accessors, so that a pass can ask either level the same question.
  (:import-from #:wolv.ir #:define-instr #:dst #:symbol-of)
  (:local-nicknames (#:ir #:wolv.ir))
  (:export #:i-mach #:form #:srcs #:imm #:effect
           #:*forms* #:form-template #:condition-code #:opposite-code
           #:expanded-p #:known-form-p #:verify #:verify-module))

(in-package #:wolv.mach)

;; How each form is written down, once the registers have their colours.  The
;; keywords name the operands the emitter has to supply: `:d` is the register
;; written and `:s0`, `:s1`, `:s2` the ones read.
(defparameter *forms*
  '(("add"  "add ~A, ~A, ~A"           :d :s0 :s1)
    ("addi" "add ~A, ~A, #~D"          :d :s0 :imm)
    ("adds" "add ~A, ~A, ~A, lsl #~D"  :d :s0 :s1 :imm)
    ("sub"  "sub ~A, ~A, ~A"           :d :s0 :s1)
    ("subi" "sub ~A, ~A, #~D"          :d :s0 :imm)
    ("subs" "sub ~A, ~A, ~A, lsl #~D"  :d :s0 :s1 :imm)
    ("mul"  "mul ~A, ~A, ~A"           :d :s0 :s1)
    ("madd" "madd ~A, ~A, ~A, ~A"      :d :s0 :s1 :s2)
    ("msub" "msub ~A, ~A, ~A, ~A"      :d :s0 :s1 :s2)
    ("sdiv" "sdiv ~A, ~A, ~A"          :d :s0 :s1)
    ("and"  "and ~A, ~A, ~A"           :d :s0 :s1)
    ("orr"  "orr ~A, ~A, ~A"           :d :s0 :s1)
    ("eor"  "eor ~A, ~A, ~A"           :d :s0 :s1)
    ("eori" "eor ~A, ~A, #~D"          :d :s0 :imm)
    ("lsl"  "lsl ~A, ~A, ~A"           :d :s0 :s1)
    ("lsli" "lsl ~A, ~A, #~D"          :d :s0 :imm)
    ("asr"  "asr ~A, ~A, ~A"           :d :s0 :s1)
    ("asri" "asr ~A, ~A, #~D"          :d :s0 :imm)
    ("cmp"  "cmp ~A, ~A"               :s0 :s1)
    ("cmpi" "cmp ~A, #~D"              :s0 :imm)
    ("cset" "cset ~A, ~A"              :d :sym)))

(defun form-template (name) (assoc name *forms* :test #'string=))
(defun known-form-p (name) (and (form-template name) t))

;; Which condition code each comparison sets, and which one says the opposite --
;; the emitter needs the opposite when the branch it is writing falls through to
;; the block the comparison was true for.
(defparameter *conditions*
  '(("=" . "eq") ("<>" . "ne") ("<" . "lt") ("<=" . "le")
    (">" . "gt") (">=" . "ge") ("u<" . "lo") ("u>=" . "hs")))

(defparameter *opposites*
  '(("eq" . "ne") ("ne" . "eq") ("lt" . "ge") ("ge" . "lt")
    ("gt" . "le") ("le" . "gt") ("lo" . "hs") ("hs" . "lo")))

(defun condition-code (op) (cdr (assoc op *conditions* :test #'string=)))
(defun opposite-code (code) (cdr (assoc code *opposites* :test #'string=)))

;; The ones the emitter writes itself, because they are not one instruction.
(defparameter *expanded* '("const" "adr" "ldr" "str"))
(defun expanded-p (name) (and (member name *expanded* :test #'string=) t))

(define-instr i-mach (form (dst :def) (srcs :uses)
                           (imm :plain 0) (symbol-of :plain "")
                           (effect :plain nil))
  (:effect effect)
  (:show (let* ((operands (append (mapcar #'% srcs)
                                  (cond ((string/= symbol-of "") (list symbol-of))
                                        ((or (/= imm 0) (string= form "const"))
                                         (list (format nil "#~D" imm)))
                                        (t '()))))
                (written (string-right-trim
                          " " (format nil "~A ~{~A~^, ~}" form operands))))
           (if dst (format nil "~A = ~A" (% dst) written) written))))

(defparameter *abstract*
  '(ir:i-const ir:i-str-const ir:i-bin ir:i-cmp ir:i-load ir:i-store))

(defun verify (f)
  "Insist that selection left nothing of the three-address IR behind."
  (dolist (b (ir:walk f))
    (dolist (i (ir:block-instrs b))
      (dolist (kind *abstract*)
        (assert (not (typep i kind)) ()
                "~A survived selection in ~A:~A"
                (class-name (class-of i)) (ir:func-name f) (ir:block-label b)))
      (when (typep i 'i-mach)
        (assert (or (known-form-p (form i)) (expanded-p (form i))) ()
                "no such instruction as `~A`" (form i))))))

(defun verify-module (m)
  (dolist (f (ir:module-funcs m)) (verify f)))

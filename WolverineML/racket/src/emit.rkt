#lang racket/base

;; ARMv8 assembly, in AAPCS64.
;;
;; The frame is the ordinary one.  `x29` points at the saved frame record, the
;; slots an escaping variable or a spill lives in are below it, the callee-saved
;; registers this function actually used are below those, and outgoing stack
;; arguments sit at the bottom, at `sp`, where the callee expects them.
;;
;;     x29 -> | saved x29, x30 |
;;            | slot 0         |   x29 - 8      also where a static link points
;;            | slot 1         |   x29 - 16
;;            | ...            |
;;            | saved x19...   |
;;     sp  -> | outgoing args  |
;;
;; The allocator this tree keeps leaves SSA before it colours, so a phi never
;; reaches here.  The copies a phi stood for are already instructions, and the
;; only parallel copies left are the ones the ABI makes at a call and in the
;; prologue — which are still parallel, and still go through `sequentialize`:
;; when they form a cycle it borrows a register the function never used, and when
;; there is none it swaps the two ends with three `eor`s, so no register has to
;; be reserved for it.

(require racket/list
         racket/match
         racket/string
         data/gvector
         "registers.rkt"
         (prefix-in copies: "copies.rkt")
         (prefix-in ir: "ir.rkt")
         (prefix-in mach: "mach.rkt"))

(provide emit-module emit-func escape borrow-nothing?)

(define UNSCALED '(("ldr" . "ldur") ("str" . "stur")))

;; The one register kept back.  A frame big enough to put a slot out of reach of
;; `ldur` is only discovered after allocation has added its spill slots, so the
;; address has to be computed somewhere the allocator does not know about.
(define SPARE (first SCRATCH))

;; Nothing of ours is live at the top of the prologue except the incoming
;; arguments, so a caller-saved register that is not one of them is free there.
(define PROLOGUE-TEMP 9)

;; -- the frame ---------------------------------------------------------------

(struct frame (slots saved stack-args size) #:transparent)

(define (frame-of f alloc)
  (define stack-args
    (for*/fold ([most 0]) ([b (in-list (ir:walk f))] [i (in-list (ir:instrs b))])
      (match i
        [(ir:i:call _ _ args) (max most (- (length args) (length ARGUMENT-REGS)))]
        [_ most])))
  (define saved (ir:allocation-saved alloc))
  (define raw (* ir:WORD (+ (ir:func-nslots f) (length saved) (max stack-args 0))))
  (frame (ir:func-nslots f) saved (max stack-args 0) (bitwise-and (+ raw 15) (bitwise-not 15))))

(define (saved-offset fr index) (* (- ir:WORD) (+ (frame-slots fr) index 1)))

;; -- one function ------------------------------------------------------------

;; `read-somewhere` is what the prologue asks before moving an argument into
;; place: a parameter nothing reads needs no `mov`.  `taken` is every colour the
;; function gave to a value, which is what says a register is free to borrow.
(struct emitter (func alloc frame out epilogue read-somewhere taken) #:transparent)

(define (new-emitter f alloc)
  (define read (make-hasheqv))
  (for ([b (in-list (ir:walk f))])
    (for* ([p (in-list (ir:block-phis b))] [a (in-list (ir:phi-args p))])
      (hash-set! read (cdr a) #t))
    (for* ([i (in-list (ir:instrs b))] [r (in-list (ir:uses i))])
      (hash-set! read r #t)))
  (define taken (make-hasheqv))
  (for ([(r colour) (in-hash (ir:allocation-colours alloc))]) (hash-set! taken colour #t))
  (emitter f alloc (frame-of f alloc) (box '())
           (format ".Lepi_~a" (ir:func-label f)) read taken))

(define (out! e text) (set-box! (emitter-out e) (cons text (unbox (emitter-out e)))))
(define (line! e text) (out! e (string-append "\t" text)))
(define (label! e text) (out! e (format "~a:" text)))

(define (colour-of e r)
  (or (hash-ref (ir:allocation-colours (emitter-alloc e)) r #f)
      (error 'emit "%~a was never coloured" r)))

(define (mov! e dst src) (unless (= dst src) (line! e (format "mov x~a, x~a" dst src))))

;; A 64-bit constant, in as many `movz`/`movk` as its non-zero halves need.
(define (immediate! e dst value)
  (define word (bitwise-and value (sub1 (arithmetic-shift 1 64))))
  (cond
    [(zero? word) (line! e (format "mov x~a, #0" dst))]
    [else
     (for/fold ([first? #t])
               ([shift (in-list '(0 16 32 48))] [i (in-naturals)])
       (define chunk (bitwise-and (arithmetic-shift word (- shift)) #xFFFF))
       (cond
         [(zero? chunk) first?]
         [else
          (line! e (format "~a x~a, #~a~a" (if first? "movz" "movk") dst chunk
                           (if (zero? i) "" (format ", lsl #~a" (* i 16)))))
          #f]))
     (void)]))

;; `ldr`/`str`, in whichever addressing mode reaches this far.
(define (access! e op reg base offset)
  (define where (if (= base 31) "sp" (format "x~a" base)))
  (cond
    [(and (<= 0 offset 32760) (zero? (modulo offset ir:WORD)))
     (line! e (format "~a x~a, [~a, #~a]" op reg where offset))]
    [(<= -256 offset 255)
     (line! e (format "~a x~a, [~a, #~a]" (cdr (assoc op UNSCALED)) reg where offset))]
    [else
     (immediate! e SPARE offset)
     (line! e (format "~a x~a, [~a, x~a]" op reg where SPARE))]))

;; -- whole functions ---------------------------------------------------------

(define (emit-func f alloc)
  (define e (new-emitter f alloc))
  (out! e (format "\t.globl ~a" (ir:func-label f)))
  (out! e (format "\t.type ~a, %function" (ir:func-label f)))
  (label! e (ir:func-label f))
  (prologue! e)
  (define order (ir:order-list f))
  (for ([name (in-list order)] [i (in-naturals)])
    (label! e (format ".L~a_~a" (ir:func-label f) name))
    (block! e (ir:block-of f name) (and (< (add1 i) (length order)) (list-ref order (add1 i)))))
  (label! e (emitter-epilogue e))
  (restore! e)
  (line! e "mov sp, x29")
  (line! e "ldp x29, x30, [sp], #16")
  (line! e "ret")
  (out! e (format "\t.size ~a, .-~a" (ir:func-label f) (ir:func-label f)))
  (reverse (unbox (emitter-out e))))

(define (prologue! e)
  (define fr (emitter-frame e))
  (line! e "stp x29, x30, [sp, #-16]!")
  (line! e "mov x29, sp")
  (unless (zero? (frame-size fr))
    (cond
      [(<= (frame-size fr) 4095) (line! e (format "sub sp, sp, #~a" (frame-size fr)))]
      [else
       (immediate! e PROLOGUE-TEMP (frame-size fr))
       (line! e (format "sub sp, sp, x~a" PROLOGUE-TEMP))]))
  (for ([reg (in-list (frame-saved fr))] [i (in-naturals)])
    (access! e "str" reg 29 (saved-offset fr i)))
  (parallel! e (for/list ([p (in-gvector (ir:func-params (emitter-func e)))]
                          [reg (in-list ARGUMENT-REGS)]
                          #:when (hash-ref (emitter-read-somewhere e) p #f))
                 (cons (colour-of e p) reg))))

(define (restore! e)
  (define fr (emitter-frame e))
  (for ([reg (in-list (frame-saved fr))] [i (in-naturals)])
    (access! e "ldr" reg 29 (saved-offset fr i))))

(define (block! e b next)
  (for ([i (in-list (drop-right (ir:instrs b) 1))]) (instruction! e i))
  (terminator! e b next))

(define (terminator! e b next)
  (define (where name) (format ".L~a_~a" (ir:func-label (emitter-func e)) name))
  (define (fall-through-to els)
    (unless (equal? els next) (line! e (format "b ~a" (where els)))))
  (match (ir:terminator b)
    [(ir:i:jmp target)
     (edge! e (ir:block-label b) target)
     (fall-through-to target)]
    ;; The flags are already set, so the branch reads them and no register.
    [(ir:i:cbr _ then els code)
     #:when (not (string=? code ""))
     (cond
       [(equal? then next) (line! e (format "b.~a ~a" (mach:opposite-of code) (where els)))]
       [else
        (line! e (format "b.~a ~a" code (where then)))
        (fall-through-to els)])]
    [(ir:i:cbr cnd then els _)
     (cond
       [(equal? then next) (line! e (format "cbz x~a, ~a" (colour-of e cnd) (where els)))]
       [else
        (line! e (format "cbnz x~a, ~a" (colour-of e cnd) (where then)))
        (fall-through-to els)])]
    [(ir:i:ret value)
     (when value (mov! e (first ARGUMENT-REGS) (colour-of e value)))
     ;; The epilogue follows the last block, so the last `ret` needs no branch.
     (when next (line! e (format "b ~a" (emitter-epilogue e))))]))

;; The copies a phi stands for, made real on this edge.  The allocator this tree
;; keeps left SSA already, so this is only ever asked of a block with no phis.
(define (edge! e source target)
  (define phis (ir:block-phis (ir:block-of (emitter-func e) target)))
  (unless (null? phis)
    (parallel! e (for/list ([p (in-list phis)])
                   (cons (colour-of e (ir:phi-dst p))
                         (colour-of e (cdr (ir:phi-arg p source))))))))

(define (parallel! e moves)
  (for ([step (in-list (copies:sequentialize moves (borrowed e moves)))])
    (match step
      [(copies:mov dst src) (mov! e dst src)]
      [(copies:swap a b)
       (line! e (format "eor x~a, x~a, x~a" a a b))
       (line! e (format "eor x~a, x~a, x~a" b a b))
       (line! e (format "eor x~a, x~a, x~a" a a b))])))

;; A register free to clobber here, if the function left one over.
;;
;; A caller-saved register this function never gave to a value holds nothing of
;; ours anywhere, and one that this copy neither reads nor writes holds nothing
;; of the copy's either.  With no such register the copies swap instead, which
;; needs no scratch at all.
;; Shut off, the copies swap instead — which is the path a test would never
;; reach on its own, because there is nearly always something to borrow.
(define borrow-nothing? (make-parameter #f))

(define (borrowed e moves)
  (define touched (append (map car moves) (map cdr moves)))
  (and (not (borrow-nothing?))
       (for/first ([reg (in-list CALLER-SAVED)]
                   #:unless (or (hash-ref (emitter-taken e) reg #f) (memv reg touched)))
         reg)))

;; -- one instruction ---------------------------------------------------------

(define (instruction! e i)
  (define (colour r) (colour-of e r))
  (match i
    [(? ir:i:machine?) (machine! e i)]
    [(ir:i:move dst src) (mov! e (colour dst) (colour src))]
    [(ir:i:load-slot dst slot) (access! e "ldr" (colour dst) 29 (ir:slot-offset slot))]
    [(ir:i:store-slot slot src) (access! e "str" (colour src) 29 (ir:slot-offset slot))]
    [(ir:i:frame-addr dst) (mov! e (colour dst) 29)]
    [(ir:i:call dst callee args) (call! e dst callee args)]
    [_ (error 'emit "cannot emit this instruction")]))

;; Write down one selected instruction, or the sequence it stands for.
(define (machine! e i)
  (match-define (ir:i:machine form dst srcs imm symbol _) i)
  (define coloured (for/list ([s (in-list srcs)]) (colour-of e s)))
  (match form
    ["const" (immediate! e (colour-of e dst) imm)]
    ["adr"
     (define d (colour-of e dst))
     (line! e (format "adrp x~a, ~a" d symbol))
     (line! e (format "add x~a, x~a, :lo12:~a" d d symbol))]
    ["ldr" (access! e "ldr" (colour-of e dst) (first coloured) imm)]
    ["str" (access! e "str" (second coloured) (first coloured) imm)]
    ;; Everything else is the table's line with its holes filled in.
    [_
     (define holes
       (append (for/list ([c (in-list coloured)] [n (in-naturals)])
                 (cons (format "{s~a}" n) (format "x~a" c)))
               (list (cons "{imm}" (number->string imm))
                     (cons "{sym}" symbol)
                     (cons "{d}" (if dst (format "x~a" (colour-of e dst)) "")))))
     (line! e (for/fold ([text (mach:form-of form)]) ([hole (in-list holes)])
                (string-replace text (car hole) (cdr hole))))]))

(define (call! e dst callee args)
  (define in-registers
    (for/list ([a (in-list args)] [reg (in-list ARGUMENT-REGS)]) (cons reg (colour-of e a))))
  (for ([a (in-list (if (> (length args) (length ARGUMENT-REGS))
                        (drop args (length ARGUMENT-REGS))
                        '()))]
        [i (in-naturals)])
    (access! e "str" (colour-of e a) 31 (* ir:WORD i)))
  (parallel! e in-registers)
  (line! e (format "bl ~a" callee))
  (when dst (mov! e (colour-of e dst) (first ARGUMENT-REGS))))

;; -- modules -----------------------------------------------------------------

;; One character of a literal is one byte; write the ones `.ascii` cannot.
(define (escape text)
  (apply string-append
         (for/list ([ch (in-bytes (string->bytes/latin-1 text))])
           (cond
             [(= ch #x22) "\\\""]
             [(= ch #x5C) "\\\\"]
             [(and (<= #x20 ch) (< ch #x7F)) (string (integer->char ch))]
             [else (format "\\~a" (~pad (number->string ch 8)))]))))

(define (~pad octal) (string-append (make-string (max 0 (- 3 (string-length octal))) #\0) octal))

(define (emit-module m allocs)
  (define out
    (append
     (list "\t.text")
     (append*
      (for/list ([f (in-list (ir:module*-funcs m))])
        (append (emit-func f (hash-ref allocs (ir:func-label f))) (list ""))))
     (if (null? (ir:module*-strings m))
         '()
         (cons "\t.section .rodata"
               (append*
                (for/list ([s (in-list (ir:module*-strings m))])
                  (list "\t.p2align 3"
                        (format "~a:" (ir:string-lit-symbol s))
                        (format "\t.quad ~a" (string-length (ir:string-lit-text s)))
                        (format "\t.ascii \"~a\"" (escape (ir:string-lit-text s)))
                        "\t.byte 0")))))
     (list "\t.section .note.GNU-stack,\"\",%progbits")))
  (string-append (string-join out "\n") "\n"))

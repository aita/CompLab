;;; ARMv8 assembly, in AAPCS64.
;;;
;;; The frame is the ordinary one.  `x29` points at the saved frame record, the
;;; slots an escaping variable or a spill lives in are below it, the
;;; callee-saved registers this function actually used are below those, and
;;; outgoing stack arguments sit at the bottom, at `sp`, where the callee
;;; expects them.
;;;
;;;     x29 -> | saved x29, x30 |
;;;            | slot 0         |   x29 - 8      also where a static link points
;;;            | slot 1         |   x29 - 16
;;;            | ...            |
;;;            | saved x19...   |
;;;     sp  -> | outgoing args  |
;;;
;;; The allocator this tree keeps leaves SSA before it colours, so a phi never
;;; reaches here.  The copies a phi stood for are already instructions, and the
;;; only parallel copies left are the ones the ABI makes at a call and in the
;;; prologue — which are still parallel, and still go through `sequentialize`:
;;; when they form a cycle it borrows a register the function never used, and
;;; when there is none it swaps the two ends with three `eor`s, so no register
;;; has to be reserved for it.

(define-module (wolv emit)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (first second any))
  #:use-module (ice-9 format)
  #:use-module (wolv registers)
  #:use-module (wolv copies)
  #:use-module (wolv ir)
  #:use-module (wolv mach)
  #:export (emit-module emit-func escape borrow-nothing?))

(define UNSCALED '(("ldr" . "ldur") ("str" . "stur")))

;; The one register kept back.  A frame big enough to put a slot out of reach of
;; `ldur` is only discovered after allocation has added its spill slots, so the
;; address has to be computed somewhere the allocator does not know about.
(define SPARE (first SCRATCH))

;; Nothing of ours is live at the top of the prologue except the incoming
;; arguments, so a caller-saved register that is not one of them is free there.
(define PROLOGUE-TEMP 9)

;; -- the frame ---------------------------------------------------------------

(define-class <frame-layout> ()
  (slots #:init-keyword #:slots #:getter frame-slots)
  (saved #:init-keyword #:saved #:getter frame-saved)
  (stack-args #:init-keyword #:stack-args #:getter frame-stack-args)
  (size #:init-keyword #:size #:getter frame-size))

(define (frame-of f alloc)
  (let ((stack-args
         (let loop ((bs (walk f)) (most 0))
           (if (null? bs)
               most
               (loop (cdr bs)
                     (let inner ((is (instrs (car bs))) (most most))
                       (cond
                        ((null? is) most)
                        ((is-a? (car is) <i-call>)
                         (inner (cdr is)
                                (max most (- (length (i-call-args (car is)))
                                             (length ARGUMENT-REGS)))))
                        (else (inner (cdr is) most)))))))))
    (let* ((saved (allocation-saved alloc))
           (raw (* WORD (+ (func-nslots f) (length saved) (max stack-args 0)))))
      (make <frame-layout> #:slots (func-nslots f) #:saved saved
            #:stack-args (max stack-args 0)
            #:size (logand (+ raw 15) (lognot 15))))))

(define (saved-offset fr index) (* (- WORD) (+ (frame-slots fr) index 1)))

;; -- one function ------------------------------------------------------------

;; `read-somewhere` is what the prologue asks before moving an argument into
;; place: a parameter nothing reads needs no `mov`.  `taken` is every colour the
;; function gave to a value, which is what says a register is free to borrow.
(define-class <emitter> ()
  (func #:init-keyword #:func #:getter emitter-func)
  (alloc #:init-keyword #:alloc #:getter emitter-alloc)
  (frame #:init-keyword #:frame #:getter emitter-frame)
  (out #:init-value '() #:accessor emitter-out)
  (epilogue #:init-keyword #:epilogue #:getter emitter-epilogue)
  (read-somewhere #:init-keyword #:read-somewhere #:getter emitter-read-somewhere)
  (taken #:init-keyword #:taken #:getter emitter-taken))

(define (new-emitter f alloc)
  (let ((read (make-hash-table))
        (taken (make-hash-table)))
    (for-each
     (lambda (b)
       (for-each (lambda (p)
                   (for-each (lambda (a) (hash-set! read (cdr a) #t)) (phi-args p)))
                 (block-phis b))
       (for-each (lambda (i)
                   (for-each (lambda (r) (hash-set! read r #t)) (uses i)))
                 (instrs b)))
     (walk f))
    (hash-for-each (lambda (r colour) (hash-set! taken colour #t))
                   (allocation-colours alloc))
    (make <emitter> #:func f #:alloc alloc #:frame (frame-of f alloc)
          #:epilogue (format #f ".Lepi_~a" (func-label f))
          #:read-somewhere read #:taken taken)))

(define (out! e text) (set! (emitter-out e) (cons text (emitter-out e))))
(define (line! e text) (out! e (string-append "\t" text)))
(define (label! e text) (out! e (format #f "~a:" text)))

(define (colour-of e r)
  (or (hash-ref (allocation-colours (emitter-alloc e)) r #f)
      (error (format #f "%~a was never coloured" r))))

(define (mov! e dst src)
  (unless (= dst src) (line! e (format #f "mov x~a, x~a" dst src))))

;; A 64-bit constant, in as many `movz`/`movk` as its non-zero halves need.
(define (immediate! e dst value)
  (let ((word (logand value (- (ash 1 64) 1))))
    (cond
     ((zero? word) (line! e (format #f "mov x~a, #0" dst)))
     (else
      (let loop ((shifts '(0 16 32 48)) (i 0) (first? #t))
        (unless (null? shifts)
          (let ((chunk (logand (ash word (- (car shifts))) #xFFFF)))
            (cond
             ((zero? chunk) (loop (cdr shifts) (+ i 1) first?))
             (else
              (line! e (format #f "~a x~a, #~a~a" (if first? "movz" "movk") dst chunk
                               (if (zero? i) "" (format #f ", lsl #~a" (* i 16)))))
              (loop (cdr shifts) (+ i 1) #f))))))))))

;; `ldr`/`str`, in whichever addressing mode reaches this far.
(define (access! e op reg base offset)
  (let ((where (if (= base 31) "sp" (format #f "x~a" base))))
    (cond
     ((and (<= 0 offset) (<= offset 32760) (zero? (modulo offset WORD)))
      (line! e (format #f "~a x~a, [~a, #~a]" op reg where offset)))
     ((and (<= -256 offset) (<= offset 255))
      (line! e (format #f "~a x~a, [~a, #~a]" (cdr (assoc op UNSCALED)) reg where offset)))
     (else
      (immediate! e SPARE offset)
      (line! e (format #f "~a x~a, [~a, x~a]" op reg where SPARE))))))

;; -- whole functions ---------------------------------------------------------

(define (emit-func f alloc)
  (let ((e (new-emitter f alloc)))
    (out! e (format #f "\t.globl ~a" (func-label f)))
    (out! e (format #f "\t.type ~a, %function" (func-label f)))
    (label! e (func-label f))
    (prologue! e)
    (let ((order (order-list f)))
      (let loop ((names order) (i 0))
        (unless (null? names)
          (label! e (format #f ".L~a_~a" (func-label f) (car names)))
          (block! e (block-of f (car names))
                  (and (< (+ i 1) (length order)) (list-ref order (+ i 1))))
          (loop (cdr names) (+ i 1)))))
    (label! e (emitter-epilogue e))
    (restore! e)
    (line! e "mov sp, x29")
    (line! e "ldp x29, x30, [sp], #16")
    (line! e "ret")
    (out! e (format #f "\t.size ~a, .-~a" (func-label f) (func-label f)))
    (reverse (emitter-out e))))

(define (prologue! e)
  (let ((fr (emitter-frame e)))
    (line! e "stp x29, x30, [sp, #-16]!")
    (line! e "mov x29, sp")
    (unless (zero? (frame-size fr))
      (cond
       ((<= (frame-size fr) 4095)
        (line! e (format #f "sub sp, sp, #~a" (frame-size fr))))
       (else
        (immediate! e PROLOGUE-TEMP (frame-size fr))
        (line! e (format #f "sub sp, sp, x~a" PROLOGUE-TEMP)))))
    (let loop ((regs (frame-saved fr)) (i 0))
      (unless (null? regs)
        (access! e "str" (car regs) 29 (saved-offset fr i))
        (loop (cdr regs) (+ i 1))))
    (parallel! e
               (let loop ((ps (func-params (emitter-func e)))
                          (regs ARGUMENT-REGS)
                          (acc '()))
                 (cond
                  ((or (null? ps) (null? regs)) (reverse acc))
                  ((hash-ref (emitter-read-somewhere e) (car ps) #f)
                   (loop (cdr ps) (cdr regs)
                         (cons (cons (colour-of e (car ps)) (car regs)) acc)))
                  (else (loop (cdr ps) (cdr regs) acc)))))))

(define (restore! e)
  (let ((fr (emitter-frame e)))
    (let loop ((regs (frame-saved fr)) (i 0))
      (unless (null? regs)
        (access! e "ldr" (car regs) 29 (saved-offset fr i))
        (loop (cdr regs) (+ i 1))))))

(define (block! e b next)
  (let ((is (instrs b)))
    (for-each (lambda (i) (instruction! e i)) (list-head is (- (length is) 1))))
  (terminator! e b next))

(define (terminator! e b next)
  (define (where name) (format #f ".L~a_~a" (func-label (emitter-func e)) name))
  (define (fall-through-to els)
    (unless (equal? els next) (line! e (format #f "b ~a" (where els)))))
  (let ((t (terminator b)))
    (cond
     ((is-a? t <i-jmp>)
      (edge! e (block-label b) (i-jmp-target t))
      (fall-through-to (i-jmp-target t)))
     ;; The flags are already set, so the branch reads them and no register.
     ((and (is-a? t <i-cbr>) (not (string=? (i-cbr-code t) "")))
      (cond
       ((equal? (i-cbr-then t) next)
        (line! e (format #f "b.~a ~a" (opposite-of (i-cbr-code t))
                         (where (i-cbr-else t)))))
       (else
        (line! e (format #f "b.~a ~a" (i-cbr-code t) (where (i-cbr-then t))))
        (fall-through-to (i-cbr-else t)))))
     ((is-a? t <i-cbr>)
      (cond
       ((equal? (i-cbr-then t) next)
        (line! e (format #f "cbz x~a, ~a" (colour-of e (i-cbr-test t))
                         (where (i-cbr-else t)))))
       (else
        (line! e (format #f "cbnz x~a, ~a" (colour-of e (i-cbr-test t))
                         (where (i-cbr-then t))))
        (fall-through-to (i-cbr-else t)))))
     (else
      (when (i-ret-value t) (mov! e (first ARGUMENT-REGS) (colour-of e (i-ret-value t))))
      ;; The epilogue follows the last block, so the last `ret` needs no branch.
      (when next (line! e (format #f "b ~a" (emitter-epilogue e))))))))

;; The copies a phi stands for, made real on this edge.  The allocator this tree
;; keeps left SSA already, so this is only ever asked of a block with no phis.
(define (edge! e source target)
  (let ((phis (block-phis (block-of (emitter-func e) target))))
    (unless (null? phis)
      (parallel! e (map (lambda (p)
                          (cons (colour-of e (phi-dst p))
                                (colour-of e (cdr (phi-arg p source)))))
                        phis)))))

(define (parallel! e moves)
  (for-each
   (lambda (step)
     (cond
      ((mov? step) (mov! e (mov-dst step) (mov-src step)))
      (else
       (let ((a (swap-a step)) (b (swap-b step)))
         (line! e (format #f "eor x~a, x~a, x~a" a a b))
         (line! e (format #f "eor x~a, x~a, x~a" b a b))
         (line! e (format #f "eor x~a, x~a, x~a" a a b))))))
   (sequentialize moves (borrowed e moves))))

;; A register free to clobber here, if the function left one over.
;;
;; A caller-saved register this function never gave to a value holds nothing of
;; ours anywhere, and one that this copy neither reads nor writes holds nothing
;; of the copy's either.  With no such register the copies swap instead, which
;; needs no scratch at all.
;;
;; Shut off, the copies swap instead — which is the path a test would never
;; reach on its own, because there is nearly always something to borrow.
(define borrow-nothing? (make-parameter #f))

(define (borrowed e moves)
  (let ((touched (append (map car moves) (map cdr moves))))
    (and (not (borrow-nothing?))
         (let loop ((regs CALLER-SAVED))
           (cond
            ((null? regs) #f)
            ((or (hash-ref (emitter-taken e) (car regs) #f) (memv (car regs) touched))
             (loop (cdr regs)))
            (else (car regs)))))))

;; -- one instruction ---------------------------------------------------------

(define-generic instruction!)

(define-method (instruction! e (i <instr>))
  (error "cannot emit this instruction"))

(define-method (instruction! e (i <i-machine>)) (machine! e i))

(define-method (instruction! e (i <i-move>))
  (mov! e (colour-of e (instr-dst i)) (colour-of e (i-move-src i))))

(define-method (instruction! e (i <i-load-slot>))
  (access! e "ldr" (colour-of e (instr-dst i)) 29 (slot-offset (i-load-slot-slot i))))

(define-method (instruction! e (i <i-store-slot>))
  (access! e "str" (colour-of e (i-store-slot-src i)) 29
           (slot-offset (i-store-slot-slot i))))

(define-method (instruction! e (i <i-frame-addr>))
  (mov! e (colour-of e (instr-dst i)) 29))

(define-method (instruction! e (i <i-call>))
  (call! e (instr-dst i) (i-call-callee i) (i-call-args i)))

;; Write down one selected instruction, or the sequence it stands for.
(define (machine! e i)
  (let* ((form (i-machine-form i))
         (dst (instr-dst i))
         (imm (i-machine-imm i))
         (symbol (i-machine-symbol i))
         (coloured (map (lambda (s) (colour-of e s)) (i-machine-srcs i))))
    (cond
     ((string=? form "const") (immediate! e (colour-of e dst) imm))
     ((string=? form "adr")
      (let ((d (colour-of e dst)))
        (line! e (format #f "adrp x~a, ~a" d symbol))
        (line! e (format #f "add x~a, x~a, :lo12:~a" d d symbol))))
     ((string=? form "ldr")
      (access! e "ldr" (colour-of e dst) (first coloured) imm))
     ((string=? form "str")
      (access! e "str" (second coloured) (first coloured) imm))
     ;; Everything else is the table's line with its holes filled in.
     (else
      (let ((holes (append (let loop ((cs coloured) (n 0) (acc '()))
                             (if (null? cs)
                                 (reverse acc)
                                 (loop (cdr cs) (+ n 1)
                                       (cons (cons (format #f "{s~a}" n)
                                                   (format #f "x~a" (car cs)))
                                             acc))))
                           (list (cons "{imm}" (number->string imm))
                                 (cons "{sym}" symbol)
                                 (cons "{d}" (if dst
                                                 (format #f "x~a" (colour-of e dst))
                                                 ""))))))
        (line! e (let loop ((text (form-of form)) (hs holes))
                   (if (null? hs)
                       text
                       (loop (fill text (car (car hs)) (cdr (car hs))) (cdr hs))))))))))

;; Every occurrence of `from` in `text`, replaced by `to`.
(define (fill text from to)
  (let ((width (string-length from)))
    (let loop ((rest text) (acc ""))
      (let ((found (string-contains rest from)))
        (if found
            (loop (substring rest (+ found width))
                  (string-append acc (substring rest 0 found) to))
            (string-append acc rest))))))

(define (call! e dst callee args)
  (let ((in-registers (let loop ((as args) (regs ARGUMENT-REGS) (acc '()))
                        (if (or (null? as) (null? regs))
                            (reverse acc)
                            (loop (cdr as) (cdr regs)
                                  (cons (cons (car regs) (colour-of e (car as))) acc))))))
    (let loop ((extra (if (> (length args) (length ARGUMENT-REGS))
                          (list-tail args (length ARGUMENT-REGS))
                          '()))
               (i 0))
      (unless (null? extra)
        (access! e "str" (colour-of e (car extra)) 31 (* WORD i))
        (loop (cdr extra) (+ i 1))))
    (parallel! e in-registers)
    (line! e (format #f "bl ~a" callee))
    (when dst (mov! e (colour-of e dst) (first ARGUMENT-REGS)))))

;; -- modules -----------------------------------------------------------------

;; One character of a literal is one byte; write the ones `.ascii` cannot.
(define (escape text)
  (string-concatenate
   (map (lambda (c)
          (let ((ch (char->integer c)))
            (cond
             ((= ch #x22) "\\\"")
             ((= ch #x5C) "\\\\")
             ((and (<= #x20 ch) (< ch #x7F)) (string (integer->char ch)))
             (else (format #f "\\~a" (padded-octal (number->string ch 8)))))))
        (string->list text))))

(define (padded-octal octal)
  (string-append (make-string (max 0 (- 3 (string-length octal))) #\0) octal))

(define (emit-module m allocs)
  (let ((out (append
              (list "\t.text")
              (append-map
               (lambda (f)
                 (append (emit-func f (hash-ref allocs (func-label f))) (list "")))
               (module-funcs m))
              (if (null? (module-strings m))
                  '()
                  (cons "\t.section .rodata"
                        (append-map
                         (lambda (s)
                           (list "\t.p2align 3"
                                 (format #f "~a:" (string-lit-symbol s))
                                 (format #f "\t.quad ~a"
                                         (string-length (string-lit-text s)))
                                 (format #f "\t.ascii \"~a\""
                                         (escape (string-lit-text s)))
                                 "\t.byte 0"))
                         (module-strings m))))
              (list "\t.section .note.GNU-stack,\"\",%progbits"))))
    (string-append (string-join out "\n") "\n")))

(define (append-map f xs) (apply append (map f xs)))

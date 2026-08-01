#lang racket/base

;; Which colour a value would like, which is the calling convention asking.
;;
;; The allocator does not have to satisfy these — a preference is dropped the
;; moment it clashes with something the colouring actually requires — but taking
;; one when it is free is what stops the emitter having to move a value into
;; `x2` on the way into a call, or out of `x0` on the way back from one.

(require racket/list
         racket/match
         data/gvector
         "registers.rkt"
         (prefix-in ir: "ir.rkt"))

(provide preferences)

;; The register each value is about to be wanted in, where there is one.
(define (preferences f)
  (define wanted (make-hasheqv))
  (for ([p (in-gvector (ir:func-params f))] [i (in-naturals)]
        #:when (< i (length ARGUMENT-REGS)))
    (hash-set! wanted p (list-ref ARGUMENT-REGS i)))
  (for* ([b (in-list (ir:walk f))] [i (in-list (ir:instrs b))])
    (match i
      [(ir:i:call dst _ args)
       (for ([arg (in-list args)] [reg (in-list ARGUMENT-REGS)]) (hash-set! wanted arg reg))
       (when dst (hash-set! wanted dst (first ARGUMENT-REGS)))]
      [(ir:i:ret (? values value)) (hash-set! wanted value (first ARGUMENT-REGS))]
      [_ (void)]))
  wanted)

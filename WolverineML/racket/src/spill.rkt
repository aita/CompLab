#lang racket/base

;; Spilling.
;;
;; A spilled value gets a frame slot, a store after every definition of it and a
;; reload in front of every use.  The reloads are new registers, live from the
;; load to the instruction under it and nowhere else, which is what makes the
;; pressure come down.  Nothing here assumes SSA: a value written twice gets two
;; stores, and a phi argument is reloaded at the end of the predecessor it comes
;; from, so the same rewrite serves the graph before and after it left SSA.

(require racket/list
         racket/set
         data/gvector
         (prefix-in ir: "ir.rkt")
         (prefix-in ssa: "ssa.rkt"))

(provide (struct-out exn:out-of-registers) out-of-registers
         loop-depth costs spill!)

;; Raised when spilling cannot help either.
(struct exn:out-of-registers exn:fail () #:transparent)

(define (out-of-registers message)
  (raise (exn:out-of-registers message (current-continuation-marks))))

;; How deeply each block is nested in loops, for weighing what a use costs.
;;
;; A back edge is an edge into a block that dominates its source; everything that
;; can reach the source without leaving the dominated region is in that loop.
(define (loop-depth f)
  (define dom (ssa:dominance-of f))
  (define depth (make-hash))
  (for ([label (in-list (ir:order-list f))]) (hash-set! depth label 0))
  (for* ([b (in-list (ir:walk f))] [succ (in-list (ir:succs b))]
         #:when (ssa:dominates? dom succ (ir:block-label b)))
    (define body (make-hash))
    (hash-set! body succ #t)
    (let walk ([stack (list (ir:block-label b))])
      (unless (null? stack)
        (define label (car stack))
        (cond
          [(hash-ref body label #f) (walk (cdr stack))]
          [else
           (hash-set! body label #t)
           (walk (append (reverse (ir:block-preds (ir:block-of f label))) (cdr stack)))])))
    (for ([label (in-hash-keys body)]) (hash-update! depth label add1 0)))
  depth)

;; What spilling a value would cost: its reads and writes, weighed by loops.
(define (costs f)
  (define depth (loop-depth f))
  (define weight (make-hasheqv))
  (define (weigh! r by) (hash-update! weight r (λ (n) (+ n by)) 0.0))
  (for ([b (in-list (ir:walk f))])
    (define scale (exact->inexact (expt 10 (min (hash-ref depth (ir:block-label b)) 4))))
    (for ([p (in-list (ir:block-phis b))])
      (for ([a (in-list (ir:phi-args p))])
        (weigh! (cdr a) (exact->inexact (expt 10 (min (hash-ref depth (car a)) 4)))))
      (weigh! (ir:phi-dst p) scale))
    (for ([i (in-list (ir:instrs b))])
      (for ([r (in-list (ir:uses i))]) (weigh! r scale))
      (define d (ir:defs i))
      (when d (weigh! d scale))))
  weight)

;; Give `victim` a frame slot, and answer with the reloads that replaced it.
(define (spill! f victim slots)
  (define slot (ir:new-slot! f))
  (hash-set! slots victim slot)
  (define param? (for/or ([p (in-gvector (ir:func-params f))]) (eqv? p victim)))
  (define reloads (make-hasheqv))

  (for ([b (in-list (ir:walk f))])
    (when (for/or ([p (in-list (ir:block-phis b))]) (eqv? (ir:phi-dst p) victim))
      (ir:set-instrs! b (cons (ir:i:store-slot slot victim) (ir:instrs b))))
    (when (and param? (equal? (ir:block-label b) (ir:func-entry f)))
      (ir:set-instrs! b (cons (ir:i:store-slot slot victim) (ir:instrs b))))
    (ir:set-instrs!
     b
     (append*
      (for/list ([i (in-list (ir:instrs b))])
        ;; The store this pass just put in reads the victim on purpose.
        (define store? (and (ir:i:store-slot? i) (= (ir:i:store-slot-slot i) slot)))
        (define reads? (and (not store?) (memv victim (ir:uses i))))
        (define fresh (and reads? (ir:new-reg! f)))
        (when fresh (hash-set! reloads fresh #t))
        (define rewritten
          (if fresh (ir:map-uses i (λ (r) (if (eqv? r victim) fresh r))) i))
        (append (if fresh (list (ir:i:load-slot fresh slot)) '())
                (list rewritten)
                (if (eqv? (ir:defs i) victim) (list (ir:i:store-slot slot victim)) '()))))))

  (for ([b (in-list (ir:walk f))])
    (ir:map-phis!
     b
     (λ (p)
       (for/fold ([p p]) ([a (in-list (ir:phi-args p))] #:when (eqv? (cdr a) victim))
         (define source (ir:block-of f (car a)))
         (define fresh (ir:new-reg! f))
         (hash-set! reloads fresh #t)
         (define at (sub1 (ir:count source)))
         (ir:set-instrs! source (append (take (ir:instrs source) at)
                                        (list (ir:i:load-slot fresh slot))
                                        (drop (ir:instrs source) at)))
         (ir:phi-set-arg (car a) fresh p)))))
  (list->seteqv (hash-keys reloads)))

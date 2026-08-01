#lang racket/base

;; Liveness on SSA.
;;
;; The only subtlety is the phi.  A phi does not read its arguments where it
;; stands; it reads them on the edges, so an argument is live at the end of the
;; predecessor it is paired with and not anywhere inside the block that holds the
;; phi.  Getting that wrong is what makes phi-related values interfere when they
;; should not.

(require racket/list
         racket/set
         (prefix-in ir: "ir.rkt"))

(provide (struct-out liveness) analyse live-in live-out across-calls pressure
         regs sorted-regs)

;; A set of registers.  Registers are small integers, so `seteqv` is the cheap
;; one, and everything that has to be walked in a fixed order goes through
;; `sorted-regs` on the way out.
(define (regs . rs) (list->seteqv rs))
(define (sorted-regs s) (sort (set->list s) <))

(struct liveness (in out) #:transparent)

(define (live-in l label) (hash-ref (liveness-in l) label))
(define (live-out l label) (hash-ref (liveness-out l) label))

(define (analyse f)
  ;; What a block reads before writing, and what it writes at all.
  (define upward (make-hash))
  (define killed (make-hash))
  (for ([b (in-list (ir:walk f))])
    (define kill (for/seteqv ([p (in-list (ir:block-phis b))]) (ir:phi-dst p)))
    (define use (seteqv))
    (for ([i (in-list (ir:instrs b))])
      (for ([r (in-list (ir:uses i))])
        (unless (set-member? kill r) (set! use (set-add use r))))
      (define d (ir:defs i))
      (when d (set! kill (set-add kill d))))
    (hash-set! upward (ir:block-label b) use)
    (hash-set! killed (ir:block-label b) kill))

  (define in (make-hash))
  (define out (make-hash))
  (for ([label (in-list (ir:order-list f))])
    (hash-set! in label (seteqv))
    (hash-set! out label (seteqv)))

  (define order (reverse (ir:rpo f)))
  (let settle ()
    (define changed #f)
    (for ([label (in-list order)])
      (define b (ir:block-of f label))
      (define leaving
        (for/fold ([leaving (seteqv)]) ([succ (in-list (ir:succs b))])
          (for/fold ([leaving (set-union leaving (hash-ref in succ))])
                    ([p (in-list (ir:block-phis (ir:block-of f succ)))])
            (define arg (ir:phi-arg p label))
            (if arg (set-add leaving (cdr arg)) leaving))))
      (define entering
        (set-union (hash-ref upward label) (set-subtract leaving (hash-ref killed label))))
      (unless (and (set=? leaving (hash-ref out label)) (set=? entering (hash-ref in label)))
        (hash-set! out label leaving)
        (hash-set! in label entering)
        (set! changed #t)))
    (when changed (settle)))
  (liveness in out))

;; Values that are live across a call, and so cannot sit in a scratch register.
(define (across-calls f l)
  (for/fold ([out (seteqv)]) ([b (in-list (ir:walk f))])
    (define-values (final answer)
      (for/fold ([after (live-out l (ir:block-label b))] [out out])
                ([i (in-list (reverse (ir:instrs b)))])
        (define d (ir:defs i))
        (define without (if d (set-remove after d) after))
        (values (set-union without (list->seteqv (ir:uses i)))
                (if (ir:i:call? i) (set-union out without) out))))
    answer))

;; The most values live at any one point — the registers the function wants.
(define (pressure f l)
  (for/fold ([most 0]) ([b (in-list (ir:walk f))])
    (define after0 (live-out l (ir:block-label b)))
    (define-values (final worst)
      (for/fold ([after after0] [most (max most (set-count after0))])
                ([i (in-list (reverse (ir:instrs b)))])
        (define d (ir:defs i))
        (define next (set-union (if d (set-remove after d) after) (list->seteqv (ir:uses i))))
        (values next (max most (set-count next)))))
    (define entry
      (set-union (live-in l (ir:block-label b))
                 (for/seteqv ([p (in-list (ir:block-phis b))]) (ir:phi-dst p))))
    (max worst (set-count entry))))

#lang racket/base

;; The seam the allocator is reached through, and the verifier it answers to.
;;
;; There is one allocator here — leave SSA, build the interference graph, colour
;; it with Chaitin's algorithm and George and Appel's iterated coalescing.  The
;; Python tree has a second one that colours the SSA itself in dominance order,
;; and keeps both so that the two can be measured against each other; this tree
;; keeps the graph.
;;
;; What comes out is an `ir:allocation` and not a field of the function: a
;; colouring is an assignment from the program's registers to the machine's, and
;; nothing but the emitter and this verifier ever reads one.

(require racket/list
         racket/set
         data/gvector
         "registers.rkt"
         (prefix-in graph: "graph.rkt")
         (prefix-in ir: "ir.rkt")
         (prefix-in live: "liveness.rkt"))

(provide allocate-module verify verify-module)

(define (allocate-module m [machine (whole-machine)])
  (for/hash ([f (in-list (ir:module*-funcs m))])
    (values (ir:func-label f) (graph:allocate f machine))))

;; No two values that hold different things at once may share a colour.
;;
;; The check is made where the interference graph joins values — at each
;; definition, and at the top of a block for the phis and the parameters, which
;; define several at once.  Looking at a whole live set instead would be wrong,
;; not merely slower: both ends of a copy are live after it and hold the same
;; value, so they may share a register, and that is the entire point of
;; coalescing.  A verifier that rejected it would reject every program the
;; coalescer had done its job on.
;;
;; Every value that interferes with another is caught this way, because the later
;; of the two definitions that put the values there happens while the other is
;; live.
(define (verify f alloc)
  (define colours (ir:allocation-colours alloc))
  (define l (live:analyse f))
  (define (coloured! r) (unless (hash-ref colours r #f) (error 'allocator "%~a has no colour" r)))
  (define (no-clash alive written where)
    (define colour (hash-ref colours written #f))
    (when colour
      (for ([other (in-list (live:sorted-regs alive))]
            #:unless (or (eqv? other written) (not (eqv? (hash-ref colours other #f) colour))))
        (error 'allocator "x~a holds %~a and %~a at once in ~a"
               colour written other where))))
  (for ([b (in-list (ir:walk f))])
    (for/fold ([alive (live:live-out l (ir:block-label b))])
              ([i (in-list (reverse (ir:instrs b)))])
      (define after (if (ir:i:move? i) (set-remove alive (ir:i:move-src i)) alive))
      (for ([r (in-list (ir:uses i))]) (coloured! r))
      (define d (ir:defs i))
      (when d
        (coloured! d)
        (no-clash (set-add after d) d (ir:block-label b)))
      (set-union (if d (set-remove after d) after) (list->seteqv (ir:uses i))))

    (define entering
      (for/fold ([entering (live:live-in l (ir:block-label b))])
                ([p (in-list (ir:block-phis b))])
        (coloured! (ir:phi-dst p))
        (define with-phi (set-add entering (ir:phi-dst p)))
        (no-clash with-phi (ir:phi-dst p) (ir:block-label b))
        with-phi))
    (when (equal? (ir:block-label b) (ir:func-entry f))
      (for/fold ([entering entering]) ([param (in-gvector (ir:func-params f))])
        (define with-param (set-add entering param))
        (no-clash with-param param (ir:block-label b))
        with-param))))

(define (verify-module m allocs)
  (for ([f (in-list (ir:module*-funcs m))])
    (verify f (hash-ref allocs (ir:func-label f)))))

#lang racket/base

;; Register allocation by graph colouring, with iterated coalescing.
;;
;; The idea is Chaitin's: build a graph whose nodes are values and whose edges
;; join values that are live at the same time, then colour it with as many
;; colours as the machine has registers.  Colouring a graph is hard in general,
;; but Kempe's observation makes it practical: a node with fewer than K
;; neighbours can always be coloured whatever happens to the rest of the graph.
;; So remove such nodes one at a time and push them on a stack; when the graph is
;; empty, pop the stack and give each node a colour its neighbours have not
;; taken.  If every remaining node has K or more neighbours, guess that one of
;; them will not get a colour and carry on — if the guess was wrong the value is
;; rewritten to live in memory and the whole thing runs again (Briggs' optimistic
;; colouring).
;;
;; On top of that sits coalescing, which is why leaving SSA first costs nothing.
;; Leaving SSA fills the predecessors of every join with copies; coalescing
;; merges the two ends of a copy so that it disappears.  Merging aggressively can
;; make a graph uncolourable, so a merge only happens when Briggs' test proves it
;; cannot: the merged node must have fewer than K neighbours of significant
;; degree.  That test is only exact enough to be useful if degrees are up to
;; date, and simplifying lowers degrees while merging raises them — so the two
;; run interleaved, with freezing (giving up on a copy so its nodes can be
;; simplified) as the way out when neither applies.  Hence "iterated" (George and
;; Appel, 1996).
;;
;; This machine has no fixed registers to colour against, so the calling
;; convention is carried as a set of colours each node may not take: a value live
;; across a call may not take a caller-saved one.  A node with `f` forbidden
;; colours and `d` neighbours needs `d + f < K` to be trivially colourable, so
;; that sum is what stands in for the degree everywhere below.

(require racket/list
         racket/match
         racket/set
         data/gvector
         "registers.rkt"
         "hints.rkt"
         "spill.rkt"
         (prefix-in ir: "ir.rkt")
         (prefix-in live: "liveness.rkt"))

(provide allocate)

;; -- sets of small integers --------------------------------------------------
;;
;; `mutable-seteqv` is what every worklist here is.  What it does not promise is
;; an order, and the order matters: which node is simplified first and which copy
;; is looked at first decide the colouring, so the two places that choose go
;; through `sorted` and `least` and a colouring is the same twice.

(define (mkset) (mutable-seteqv))
(define (in? s x) (set-member? s x))
(define (add! s x) (set-add! s x))
(define (rm! s x) (set-remove! s x))
(define (any? s) (not (set-empty? s)))
(define (sorted s) (sort (set->list s) <))
(define (least s) (apply min (set->list s)))

;; -- the colouring -----------------------------------------------------------

;; `protected` holds values a previous round produced by reloading something.
;; Their live ranges are a load and its one use, so spilling one again would only
;; make another of the same, and the rewriting would never end.
(struct colouring
  (func machine protected
        adjacent degree forbidden preferred
        moves moves-of worklist-moves active-moves
        simplify-worklist freeze-worklist spill-worklist
        select-stack on-stack coalesced alias colour)
  #:transparent)

(define (new-colouring f machine protected)
  (colouring f machine protected
             (make-hasheqv) (make-hasheqv) (make-hasheqv) (make-hasheqv)
             (make-gvector) (make-hasheqv) (mkset) (mkset)
             (mkset) (mkset) (mkset)
             (box '()) (mkset) (mkset) (make-hasheqv) (make-hasheqv)))

(define (k c) (register-count (colouring-machine c)))

;; Colour `f`, rewriting and starting again for as long as it spills.
(define (allocate f machine)
  (define protected (seteqv))
  (define slots (make-hasheqv))
  (let round ([protected protected])
    (ir:recompute-preds! f)
    (define c (new-colouring f machine protected))
    (define spilled (run c))
    (cond
      [(set-empty? spilled)
       (define colours (colouring-colour c))
       (ir:allocation
        (for/hasheqv ([(r colour) (in-hash colours)]) (values r colour))
        (sort (set->list (for/seteqv ([(r colour) (in-hash colours)]
                                      #:when (memv colour CALLEE-SAVED))
                           colour))
              <)
        (for/hasheqv ([(r slot) (in-hash slots)]) (values r slot)))]
      [else
       (round
        (for/fold ([protected protected]) ([victim (in-list (sorted spilled))])
          (when (set-member? protected victim)
            (out-of-registers
             (format "`~a` needs more registers at once than the machine has"
                     (ir:func-name f))))
          (set-union protected (spill! f victim slots))))])))

(define (run c)
  (build! c)
  (make-worklists! c)
  (let loop ()
    (when (or (any? (colouring-simplify-worklist c))
              (any? (colouring-worklist-moves c))
              (any? (colouring-freeze-worklist c))
              (any? (colouring-spill-worklist c)))
      (cond
        [(any? (colouring-simplify-worklist c)) (simplify! c)]
        [(any? (colouring-worklist-moves c)) (coalesce! c)]
        [(any? (colouring-freeze-worklist c)) (freeze! c)]
        [else (select-spill! c)])
      (loop)))
  (assign-colours! c))

;; -- the graph ---------------------------------------------------------------

(define (node! c r)
  (unless (hash-ref (colouring-adjacent c) r #f)
    (hash-set! (colouring-adjacent c) r (mkset))
    (hash-set! (colouring-degree c) r 0)
    (hash-set! (colouring-forbidden c) r (mkset))))

(define (adjacent c r) (hash-ref (colouring-adjacent c) r))
(define (forbidden c r) (hash-ref (colouring-forbidden c) r))
(define (degree c r) (hash-ref (colouring-degree c) r))

(define (add-edge! c a b)
  (unless (or (eqv? a b) (in? (adjacent c a) b))
    (add! (adjacent c a) b)
    (add! (adjacent c b) a)
    (hash-update! (colouring-degree c) a add1)
    (hash-update! (colouring-degree c) b add1)))

;; The degree, counting a forbidden colour as a neighbour holding it.
(define (weight c r) (+ (degree c r) (set-count (forbidden c r))))

(define (build! c)
  (define f (colouring-func c))
  (for ([(r colour) (in-hash (preferences f))]) (hash-set! (colouring-preferred c) r colour))
  (define l (live:analyse f))
  (define caller-saved (registers-caller (colouring-machine c)))
  (for* ([b (in-list (ir:walk f))] [i (in-list (ir:instrs b))])
    (for ([r (in-list (ir:uses i))]) (node! c r))
    (when (ir:defs i) (node! c (ir:defs i))))
  (for ([r (in-gvector (ir:func-params f))]) (node! c r))

  (for ([b (in-list (ir:walk f))])
    (define alive (mkset))
    (for ([r (in-list (live:sorted-regs (live:live-out l (ir:block-label b))))]) (add! alive r))
    (for ([i (in-list (reverse (ir:instrs b)))])
      (match i
        [(ir:i:move dst src)
         (rm! alive src)
         (define index (gvector-count (colouring-moves c)))
         (gvector-add! (colouring-moves c) (cons dst src))
         (for ([end (in-list (list dst src))])
           (add! (hash-ref! (colouring-moves-of c) end mkset) index))
         (add! (colouring-worklist-moves c) index)]
        [_ (void)])
      (define defined (ir:defs i))
      (when defined
        (add! alive defined)
        (for ([other (in-list (sorted alive))]) (add-edge! c defined other)))
      ;; A value live across a call cannot sit in a caller-saved register.
      (when (ir:i:call? i)
        (for ([r (in-list (sorted alive))] #:unless (eqv? r defined))
          (for ([colour (in-list caller-saved)]) (add! (forbidden c r) colour))))
      (when defined (rm! alive defined))
      (for ([r (in-list (ir:uses i))]) (add! alive r)))
    (when (equal? (ir:block-label b) (ir:func-entry f)) (entry-edges! c alive))))

;; Parameters arrive together, so they interfere with each other.
(define (entry-edges! c alive)
  (define params (gvector->list (ir:func-params (colouring-func c))))
  (for ([param (in-list params)] [i (in-naturals)])
    (for ([other (in-list (sorted alive))]) (add-edge! c param other))
    (for ([another (in-list (drop params (add1 i)))]) (add-edge! c param another))))

;; -- the worklists -----------------------------------------------------------

(define (make-worklists! c)
  (for ([r (in-list (sort (hash-keys (colouring-adjacent c)) <))])
    (cond
      [(>= (weight c r) (k c)) (add! (colouring-spill-worklist c) r)]
      [(move-related? c r) (add! (colouring-freeze-worklist c) r)]
      [else (add! (colouring-simplify-worklist c) r)])))

(define (node-moves c r)
  (define mine (hash-ref (colouring-moves-of c) r #f))
  (if mine
      (for/list ([index (in-list (sorted mine))]
                 #:when (or (in? (colouring-active-moves c) index)
                            (in? (colouring-worklist-moves c) index)))
        index)
      '()))

(define (move-related? c r) (pair? (node-moves c r)))

(define (neighbours c r)
  (for/list ([other (in-list (sorted (adjacent c r)))]
             #:unless (or (in? (colouring-on-stack c) other)
                          (in? (colouring-coalesced c) other)))
    other))

(define (simplify! c)
  (define r (least (colouring-simplify-worklist c)))
  (rm! (colouring-simplify-worklist c) r)
  (set-box! (colouring-select-stack c) (cons r (unbox (colouring-select-stack c))))
  (add! (colouring-on-stack c) r)
  (for ([other (in-list (neighbours c r))]) (decrement-degree! c other)))

(define (decrement-degree! c r)
  (define was (weight c r))
  (hash-update! (colouring-degree c) r sub1)
  (when (= was (k c))
    ;; It has just become trivially colourable, so the copies around it may have
    ;; become safe to merge as well.
    (enable-moves! c (append (neighbours c r) (list r)))
    (rm! (colouring-spill-worklist c) r)
    (if (move-related? c r)
        (add! (colouring-freeze-worklist c) r)
        (add! (colouring-simplify-worklist c) r))))

(define (enable-moves! c nodes)
  (for* ([r (in-list nodes)] [index (in-list (node-moves c r))]
         #:when (in? (colouring-active-moves c) index))
    (rm! (colouring-active-moves c) index)
    (add! (colouring-worklist-moves c) index)))

;; -- coalescing --------------------------------------------------------------

(define (get-alias c r)
  (let follow ([r r])
    (if (in? (colouring-coalesced c) r) (follow (hash-ref (colouring-alias c) r)) r)))

(define (coalesce! c)
  (define index (least (colouring-worklist-moves c)))
  (define move (gvector-ref (colouring-moves c) index))
  (rm! (colouring-worklist-moves c) index)
  (define u (get-alias c (car move)))
  (define v (get-alias c (cdr move)))
  (cond
    [(eqv? u v) (add-to-worklist! c u)]
    [(in? (adjacent c u) v) (add-to-worklist! c u) (add-to-worklist! c v)]
    [(conservative? c u v) (combine! c u v) (add-to-worklist! c u)]
    [else (add! (colouring-active-moves c) index)]))

(define (add-to-worklist! c r)
  (when (and (< (weight c r) (k c)) (not (move-related? c r)))
    (rm! (colouring-freeze-worklist c) r)
    (add! (colouring-simplify-worklist c) r)))

;; Briggs: the merged node must have fewer than K significant neighbours.  The
;; colours the two ends may not take add up as well, and a colour the merged node
;; is barred from is one more thing standing in its way.
(define (conservative? c u v)
  (define together (set-union (list->seteqv (neighbours c u)) (list->seteqv (neighbours c v))))
  (define barred (set-count (set-union (list->seteqv (set->list (forbidden c u)))
                                       (list->seteqv (set->list (forbidden c v))))))
  (define significant
    (for/sum ([r (in-set together)]) (if (>= (weight c r) (k c)) 1 0)))
  (< (+ significant barred) (k c)))

(define (combine! c u v)
  (rm! (colouring-freeze-worklist c) v)
  (rm! (colouring-spill-worklist c) v)
  (add! (colouring-coalesced c) v)
  (hash-set! (colouring-alias c) v u)
  (unless (hash-ref (colouring-moves-of c) u #f)
    (hash-set! (colouring-moves-of c) u (mkset)))
  (for ([index (in-list (sorted (hash-ref (colouring-moves-of c) v (mkset))))])
    (add! (hash-ref (colouring-moves-of c) u) index))
  (for ([colour (in-list (sorted (forbidden c v)))]) (add! (forbidden c u) colour))
  (when (and (hash-ref (colouring-preferred c) v #f)
             (not (hash-ref (colouring-preferred c) u #f)))
    (hash-set! (colouring-preferred c) u (hash-ref (colouring-preferred c) v)))
  (enable-moves! c (list v))
  (for ([other (in-list (neighbours c v))])
    (add-edge! c other u)
    (decrement-degree! c other))
  (when (and (>= (weight c u) (k c)) (in? (colouring-freeze-worklist c) u))
    (rm! (colouring-freeze-worklist c) u)
    (add! (colouring-spill-worklist c) u)))

;; -- freezing and spilling ---------------------------------------------------

(define (freeze! c)
  (define r (least (colouring-freeze-worklist c)))
  (rm! (colouring-freeze-worklist c) r)
  (add! (colouring-simplify-worklist c) r)
  (freeze-moves! c r))

(define (freeze-moves! c r)
  (for ([index (in-list (node-moves c r))])
    (define move (gvector-ref (colouring-moves c) index))
    (rm! (colouring-active-moves c) index)
    (rm! (colouring-worklist-moves c) index)
    (define end (if (eqv? (get-alias c (car move)) (get-alias c r)) (cdr move) (car move)))
    (define other (get-alias c end))
    (when (and (not (move-related? c other)) (< (weight c other) (k c)))
      (rm! (colouring-freeze-worklist c) other)
      (add! (colouring-simplify-worklist c) other))))

;; Guess that the value with the most neighbours per use will not fit.
;;
;; Never a reload, though: those are cheap by that measure precisely because they
;; were made cheap, and choosing one would undo the last round's work instead of
;; the pressure.
(define (select-spill! c)
  (define weights (costs (colouring-func c)))
  (define unprotected
    (for/list ([r (in-list (sorted (colouring-spill-worklist c)))]
               #:unless (set-member? (colouring-protected c) r))
      r))
  (define among (if (null? unprotected) (sorted (colouring-spill-worklist c)) unprotected))
  (define (score r) (/ (weight c r) (+ (hash-ref weights r 0.0) 1.0)))
  (define chosen
    (for/fold ([chosen (first among)]) ([r (in-list (rest among))])
      (if (> (score r) (score chosen)) r chosen)))
  (rm! (colouring-spill-worklist c) chosen)
  (add! (colouring-simplify-worklist c) chosen)
  (freeze-moves! c chosen))

;; -- handing out the colours -------------------------------------------------

(define (assign-colours! c)
  (define spilled (mkset))
  (define colour (colouring-colour c))
  (let pop ()
    (define stack (unbox (colouring-select-stack c)))
    (unless (null? stack)
      (define r (car stack))
      (set-box! (colouring-select-stack c) (cdr stack))
      (rm! (colouring-on-stack c) r)
      (define taken
        (for/seteqv ([other (in-list (sorted (adjacent c r)))]
                     #:when (hash-ref colour (get-alias c other) #f))
          (hash-ref colour (get-alias c other))))
      (define free
        (for/list ([candidate (in-list (anywhere (colouring-machine c)))]
                   #:unless (or (set-member? taken candidate) (in? (forbidden c r) candidate)))
          candidate))
      (cond
        [(null? free) (add! spilled r)]
        [else
         (define want (hash-ref (colouring-preferred c) r #f))
         (hash-set! colour r (if (and want (memv want free)) want (first free)))])
      (pop)))
  (for ([r (in-list (sorted (colouring-coalesced c)))])
    (hash-set! colour r (hash-ref colour (get-alias c r)
                                  (first (anywhere (colouring-machine c))))))
  spilled)

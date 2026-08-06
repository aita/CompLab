;;; Register allocation by graph colouring, with iterated coalescing.
;;;
;;; The idea is Chaitin's: build a graph whose nodes are values and whose edges
;;; join values that are live at the same time, then colour it with as many
;;; colours as the machine has registers.  Colouring a graph is hard in general,
;;; but Kempe's observation makes it practical: a node with fewer than K
;;; neighbours can always be coloured whatever happens to the rest of the graph.
;;; So remove such nodes one at a time and push them on a stack; when the graph
;;; is empty, pop the stack and give each node a colour its neighbours have not
;;; taken.  If every remaining node has K or more neighbours, guess that one of
;;; them will not get a colour and carry on — if the guess was wrong the value
;;; is rewritten to live in memory and the whole thing runs again (Briggs'
;;; optimistic colouring).
;;;
;;; On top of that sits coalescing, which is why leaving SSA first costs
;;; nothing.  Leaving SSA fills the predecessors of every join with copies;
;;; coalescing merges the two ends of a copy so that it disappears.  Merging
;;; aggressively can make a graph uncolourable, so a merge only happens when
;;; Briggs' test proves it cannot: the merged node must have fewer than K
;;; neighbours of significant degree.  That test is only exact enough to be
;;; useful if degrees are up to date, and simplifying lowers degrees while
;;; merging raises them — so the two run interleaved, with freezing (giving up
;;; on a copy so its nodes can be simplified) as the way out when neither
;;; applies.  Hence "iterated" (George and Appel, 1996).
;;;
;;; This machine has no fixed registers to colour against, so the calling
;;; convention is carried as a set of colours each node may not take: a value
;;; live across a call may not take a caller-saved one.  A node with `f`
;;; forbidden colours and `d` neighbours needs `d + f < K` to be trivially
;;; colourable, so that sum is what stands in for the degree everywhere below.

(define-module (wolv graph)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (first))
  #:use-module (ice-9 format)
  #:use-module (wolv registers)
  #:use-module (wolv hints)
  #:use-module (wolv spill)
  #:use-module (wolv ir)
  #:use-module (wolv liveness)
  #:use-module (wolv regset)
  #:export (allocate))

;; -- sets of small integers --------------------------------------------------
;;
;; Every worklist here is a hash table used as a set.  What a hash table does
;; not promise is an order, and the order matters: which node is simplified
;; first and which copy is looked at first decide the colouring, so the two
;; places that choose go through `sorted` and `least` and a colouring is the
;; same twice.

(define (mkset) (make-hash-table))
(define (in? s x) (hash-ref s x #f))
(define (add! s x) (hash-set! s x #t))
(define (rm! s x) (hash-remove! s x))
(define (any? s) (> (hash-count (const #t) s) 0))
(define (set-size s) (hash-count (const #t) s))
(define (sorted s) (sort (hash-map->list (lambda (k v) k) s) <))
(define (least s) (apply min (hash-map->list (lambda (k v) k) s)))

;; -- the colouring -----------------------------------------------------------

;; `protected` holds values a previous round produced by reloading something.
;; Their live ranges are a load and its one use, so spilling one again would
;; only make another of the same, and the rewriting would never end.
(define-class <colouring> ()
  (func #:init-keyword #:func #:getter colouring-func)
  (machine #:init-keyword #:machine #:getter colouring-machine)
  (protected #:init-keyword #:protected #:getter colouring-protected)
  (adjacent #:init-thunk mkset #:getter colouring-adjacent)
  (degree #:init-thunk mkset #:getter colouring-degree)
  (forbidden #:init-thunk mkset #:getter colouring-forbidden)
  (preferred #:init-thunk mkset #:getter colouring-preferred)
  (moves #:init-thunk mkset #:getter colouring-moves)
  (nmoves #:init-value 0 #:accessor colouring-nmoves)
  (moves-of #:init-thunk mkset #:getter colouring-moves-of)
  (worklist-moves #:init-thunk mkset #:getter colouring-worklist-moves)
  (active-moves #:init-thunk mkset #:getter colouring-active-moves)
  (simplify-worklist #:init-thunk mkset #:getter colouring-simplify-worklist)
  (freeze-worklist #:init-thunk mkset #:getter colouring-freeze-worklist)
  (spill-worklist #:init-thunk mkset #:getter colouring-spill-worklist)
  (select-stack #:init-value '() #:accessor colouring-select-stack)
  (on-stack #:init-thunk mkset #:getter colouring-on-stack)
  (coalesced #:init-thunk mkset #:getter colouring-coalesced)
  (alias #:init-thunk mkset #:getter colouring-alias)
  (colour #:init-thunk mkset #:getter colouring-colour))

(define (new-colouring f machine protected)
  (make <colouring> #:func f #:machine machine #:protected protected))

(define (k c) (register-count (colouring-machine c)))

;; Colour `f`, rewriting and starting again for as long as it spills.
(define (allocate f machine)
  (let ((slots (make-hash-table)))
    (let round ((protected regset-empty))
      (recompute-preds! f)
      (let* ((c (new-colouring f machine protected))
             (spilled (run c)))
        (cond
         ((not (any? spilled))
          (let ((colours (colouring-colour c)))
            (allocation
             colours
             (delete-duplicates-sorted
              (sort (hash-fold (lambda (r colour acc)
                                 (if (memv colour CALLEE-SAVED) (cons colour acc) acc))
                               '() colours)
                    <))
             slots)))
         (else
          (round
           (let loop ((victims (sorted spilled)) (protected protected))
             (cond
              ((null? victims) protected)
              (else
               (when (regset-member? protected (car victims))
                 (out-of-registers
                  (format #f "`~a` needs more registers at once than the machine has"
                          (func-name f))))
               (loop (cdr victims)
                     (regset-union protected (spill! f (car victims) slots)))))))))))))

(define (delete-duplicates-sorted xs)
  (let loop ((xs xs) (acc '()))
    (cond
     ((null? xs) (reverse acc))
     ((and (pair? acc) (= (car acc) (car xs))) (loop (cdr xs) acc))
     (else (loop (cdr xs) (cons (car xs) acc))))))

(define (run c)
  (build! c)
  (make-worklists! c)
  (let loop ()
    (when (or (any? (colouring-simplify-worklist c))
              (any? (colouring-worklist-moves c))
              (any? (colouring-freeze-worklist c))
              (any? (colouring-spill-worklist c)))
      (cond
       ((any? (colouring-simplify-worklist c)) (simplify! c))
       ((any? (colouring-worklist-moves c)) (coalesce! c))
       ((any? (colouring-freeze-worklist c)) (freeze! c))
       (else (select-spill! c)))
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
    (hash-set! (colouring-degree c) a (+ 1 (degree c a)))
    (hash-set! (colouring-degree c) b (+ 1 (degree c b)))))

;; The degree, counting a forbidden colour as a neighbour holding it.
(define (weight c r) (+ (degree c r) (set-size (forbidden c r))))

(define (add-move! c dst src)
  (let ((index (colouring-nmoves c)))
    (hash-set! (colouring-moves c) index (cons dst src))
    (set! (colouring-nmoves c) (+ index 1))
    index))

(define (move-at c index) (hash-ref (colouring-moves c) index))

(define (build! c)
  (let ((f (colouring-func c)))
    (hash-for-each (lambda (r colour) (hash-set! (colouring-preferred c) r colour))
                   (preferences f))
    (let ((l (analyse f))
          (caller-saved (registers-caller (colouring-machine c))))
      (for-each
       (lambda (b)
         (for-each (lambda (i)
                     (for-each (lambda (r) (node! c r)) (uses i))
                     (when (defs i) (node! c (defs i))))
                   (instrs b)))
       (walk f))
      (for-each (lambda (r) (node! c r)) (func-params f))

      (for-each
       (lambda (b)
         (let ((alive (mkset)))
           (for-each (lambda (r) (add! alive r))
                     (regset->list (live-out l (block-label b))))
           (for-each
            (lambda (i)
              (when (is-a? i <i-move>)
                (let ((dst (instr-dst i)) (src (i-move-src i)))
                  (rm! alive src)
                  (let ((index (add-move! c dst src)))
                    (for-each
                     (lambda (end)
                       (let ((mine (or (hash-ref (colouring-moves-of c) end #f)
                                       (let ((s (mkset)))
                                         (hash-set! (colouring-moves-of c) end s)
                                         s))))
                         (add! mine index)))
                     (list dst src))
                    (add! (colouring-worklist-moves c) index))))
              (let ((defined (defs i)))
                (when defined
                  (add! alive defined)
                  (for-each (lambda (other) (add-edge! c defined other)) (sorted alive)))
                ;; A value live across a call cannot sit in a caller-saved
                ;; register.
                (when (is-a? i <i-call>)
                  (for-each (lambda (r)
                              (unless (eqv? r defined)
                                (for-each (lambda (colour) (add! (forbidden c r) colour))
                                          caller-saved)))
                            (sorted alive)))
                (when defined (rm! alive defined)))
              (for-each (lambda (r) (add! alive r)) (uses i)))
            (reverse (instrs b)))
           (when (equal? (block-label b) (func-entry f)) (entry-edges! c alive))))
       (walk f)))))

;; Parameters arrive together, so they interfere with each other.
(define (entry-edges! c alive)
  (let ((params (func-params (colouring-func c))))
    (let loop ((ps params) (i 0))
      (unless (null? ps)
        (for-each (lambda (other) (add-edge! c (car ps) other)) (sorted alive))
        (for-each (lambda (another) (add-edge! c (car ps) another))
                  (list-tail params (+ i 1)))
        (loop (cdr ps) (+ i 1))))))

;; -- the worklists -----------------------------------------------------------

(define (make-worklists! c)
  (for-each
   (lambda (r)
     (cond
      ((>= (weight c r) (k c)) (add! (colouring-spill-worklist c) r))
      ((move-related? c r) (add! (colouring-freeze-worklist c) r))
      (else (add! (colouring-simplify-worklist c) r))))
   (sorted (colouring-adjacent c))))

(define (node-moves c r)
  (let ((mine (hash-ref (colouring-moves-of c) r #f)))
    (if mine
        (filter (lambda (index) (or (in? (colouring-active-moves c) index)
                                    (in? (colouring-worklist-moves c) index)))
                (sorted mine))
        '())))

(define (move-related? c r) (pair? (node-moves c r)))

(define (neighbours c r)
  (filter (lambda (other) (not (or (in? (colouring-on-stack c) other)
                                   (in? (colouring-coalesced c) other))))
          (sorted (adjacent c r))))

(define (simplify! c)
  (let ((r (least (colouring-simplify-worklist c))))
    (rm! (colouring-simplify-worklist c) r)
    (set! (colouring-select-stack c) (cons r (colouring-select-stack c)))
    (add! (colouring-on-stack c) r)
    (for-each (lambda (other) (decrement-degree! c other)) (neighbours c r))))

(define (decrement-degree! c r)
  (let ((was (weight c r)))
    (hash-set! (colouring-degree c) r (- (degree c r) 1))
    (when (= was (k c))
      ;; It has just become trivially colourable, so the copies around it may
      ;; have become safe to merge as well.
      (enable-moves! c (append (neighbours c r) (list r)))
      (rm! (colouring-spill-worklist c) r)
      (if (move-related? c r)
          (add! (colouring-freeze-worklist c) r)
          (add! (colouring-simplify-worklist c) r)))))

(define (enable-moves! c nodes)
  (for-each
   (lambda (r)
     (for-each (lambda (index)
                 (when (in? (colouring-active-moves c) index)
                   (rm! (colouring-active-moves c) index)
                   (add! (colouring-worklist-moves c) index)))
               (node-moves c r)))
   nodes))

;; -- coalescing --------------------------------------------------------------

(define (get-alias c r)
  (let follow ((r r))
    (if (in? (colouring-coalesced c) r)
        (follow (hash-ref (colouring-alias c) r))
        r)))

(define (coalesce! c)
  (let* ((index (least (colouring-worklist-moves c)))
         (move (move-at c index)))
    (rm! (colouring-worklist-moves c) index)
    (let ((u (get-alias c (car move)))
          (v (get-alias c (cdr move))))
      (cond
       ((eqv? u v) (add-to-worklist! c u))
       ((in? (adjacent c u) v) (add-to-worklist! c u) (add-to-worklist! c v))
       ((conservative? c u v) (combine! c u v) (add-to-worklist! c u))
       (else (add! (colouring-active-moves c) index))))))

(define (add-to-worklist! c r)
  (when (and (< (weight c r) (k c)) (not (move-related? c r)))
    (rm! (colouring-freeze-worklist c) r)
    (add! (colouring-simplify-worklist c) r)))

;; Briggs: the merged node must have fewer than K significant neighbours.  The
;; colours the two ends may not take add up as well, and a colour the merged
;; node is barred from is one more thing standing in its way.
(define (conservative? c u v)
  (let* ((together (regset-union (regset-of-list (neighbours c u))
                                 (regset-of-list (neighbours c v))))
         (barred (regset-count (regset-union (regset-of-list (sorted (forbidden c u)))
                                             (regset-of-list (sorted (forbidden c v))))))
         (significant (length (filter (lambda (r) (>= (weight c r) (k c))) together))))
    (< (+ significant barred) (k c))))

(define (combine! c u v)
  (rm! (colouring-freeze-worklist c) v)
  (rm! (colouring-spill-worklist c) v)
  (add! (colouring-coalesced c) v)
  (hash-set! (colouring-alias c) v u)
  (unless (hash-ref (colouring-moves-of c) u #f)
    (hash-set! (colouring-moves-of c) u (mkset)))
  (for-each (lambda (index) (add! (hash-ref (colouring-moves-of c) u) index))
            (sorted (or (hash-ref (colouring-moves-of c) v #f) (mkset))))
  (for-each (lambda (colour) (add! (forbidden c u) colour)) (sorted (forbidden c v)))
  (when (and (hash-ref (colouring-preferred c) v #f)
             (not (hash-ref (colouring-preferred c) u #f)))
    (hash-set! (colouring-preferred c) u (hash-ref (colouring-preferred c) v)))
  (enable-moves! c (list v))
  (for-each (lambda (other)
              (add-edge! c other u)
              (decrement-degree! c other))
            (neighbours c v))
  (when (and (>= (weight c u) (k c)) (in? (colouring-freeze-worklist c) u))
    (rm! (colouring-freeze-worklist c) u)
    (add! (colouring-spill-worklist c) u)))

;; -- freezing and spilling ---------------------------------------------------

(define (freeze! c)
  (let ((r (least (colouring-freeze-worklist c))))
    (rm! (colouring-freeze-worklist c) r)
    (add! (colouring-simplify-worklist c) r)
    (freeze-moves! c r)))

(define (freeze-moves! c r)
  (for-each
   (lambda (index)
     (let ((move (move-at c index)))
       (rm! (colouring-active-moves c) index)
       (rm! (colouring-worklist-moves c) index)
       (let* ((end (if (eqv? (get-alias c (car move)) (get-alias c r))
                       (cdr move)
                       (car move)))
              (other (get-alias c end)))
         (when (and (not (move-related? c other)) (< (weight c other) (k c)))
           (rm! (colouring-freeze-worklist c) other)
           (add! (colouring-simplify-worklist c) other)))))
   (node-moves c r)))

;; Guess that the value with the most neighbours per use will not fit.
;;
;; Never a reload, though: those are cheap by that measure precisely because
;; they were made cheap, and choosing one would undo the last round's work
;; instead of the pressure.
(define (select-spill! c)
  (let* ((weights (costs (colouring-func c)))
         (unprotected (filter (lambda (r)
                                (not (regset-member? (colouring-protected c) r)))
                              (sorted (colouring-spill-worklist c))))
         (among (if (null? unprotected) (sorted (colouring-spill-worklist c)) unprotected))
         (score (lambda (r) (/ (weight c r) (+ (hash-ref weights r 0.0) 1.0))))
         (chosen (let loop ((rs (cdr among)) (chosen (car among)))
                   (cond
                    ((null? rs) chosen)
                    ((> (score (car rs)) (score chosen)) (loop (cdr rs) (car rs)))
                    (else (loop (cdr rs) chosen))))))
    (rm! (colouring-spill-worklist c) chosen)
    (add! (colouring-simplify-worklist c) chosen)
    (freeze-moves! c chosen)))

;; -- handing out the colours -------------------------------------------------

(define (assign-colours! c)
  (let ((spilled (mkset))
        (colour (colouring-colour c)))
    (let pop ()
      (let ((stack (colouring-select-stack c)))
        (unless (null? stack)
          (let ((r (car stack)))
            (set! (colouring-select-stack c) (cdr stack))
            (rm! (colouring-on-stack c) r)
            (let* ((taken (let loop ((others (sorted (adjacent c r))) (acc regset-empty))
                            (cond
                             ((null? others) acc)
                             (else
                              (let ((it (hash-ref colour (get-alias c (car others)) #f)))
                                (loop (cdr others)
                                      (if it (regset-add acc it) acc)))))))
                   (free (filter (lambda (candidate)
                                   (not (or (regset-member? taken candidate)
                                            (in? (forbidden c r) candidate))))
                                 (anywhere (colouring-machine c)))))
              (cond
               ((null? free) (add! spilled r))
               (else
                (let ((want (hash-ref (colouring-preferred c) r #f)))
                  (hash-set! colour r (if (and want (memv want free))
                                          want
                                          (first free))))))))
          (pop))))
    (for-each (lambda (r)
                (hash-set! colour r
                           (hash-ref colour (get-alias c r)
                                     (first (anywhere (colouring-machine c))))))
              (sorted (colouring-coalesced c)))
    spilled))

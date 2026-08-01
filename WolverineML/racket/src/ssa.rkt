#lang racket/base

;; SSA construction, the textbook way.
;;
;; Dominators by the iterative algorithm of Cooper, Harvey and Kennedy, dominance
;; frontiers from those, phis at the frontiers of every definition, and then one
;; walk of the dominator tree renaming as it goes.  This is minimal SSA and
;; nothing cleverer: a phi is placed wherever the frontier says, whether or not
;; the variable is live there, and the dead ones leave in `opt.rkt`.
;;
;; Only registers written more than once take part.  Everything lowering produced
;; once — a temporary — is already in SSA and is left with the name it has.

(require racket/list
         data/gvector
         (prefix-in ir: "ir.rkt"))

(provide (struct-out dominance) dominates? dominance-of
         construct! construct-module! split-critical-edges! verify
         label<? sorted-labels)

;; Blocks are named, so every set of them is walked in name order, which is what
;; keeps two runs — and two implementations — placing phis identically.
(define (label<? a b) (string<? a b))
(define (sorted-labels h) (sort (hash-keys h) label<?))

(struct dominance (idom children frontier order) #:transparent)

(define (dominates? dom a b)
  (let loop ([b b])
    (cond
      [(equal? a b) #t]
      [else
       (define parent (hash-ref (dominance-idom dom) b))
       (if (equal? parent b) #f (loop parent))])))

(define (dominance-of f)
  (define order (ir:rpo f))
  (define rank (make-hash))
  (for ([label (in-list order)] [i (in-naturals)]) (hash-set! rank label i))
  (define idom (make-hash))
  (hash-set! idom (ir:func-entry f) (ir:func-entry f))

  ;; The two runners climb until they meet, each time from the deeper one.
  (define (intersect a b)
    (let loop ([a a] [b b])
      (cond
        [(equal? a b) a]
        [else
         (define a* (let up ([a a])
                      (if (> (hash-ref rank a) (hash-ref rank b)) (up (hash-ref idom a)) a)))
         (define b* (let up ([b b])
                      (if (> (hash-ref rank b) (hash-ref rank a*)) (up (hash-ref idom b)) b)))
         (loop a* b*)])))

  (let settle ()
    (define changed #f)
    (for ([label (in-list (if (null? order) '() (cdr order)))])
      (define preds
        (for/list ([p (in-list (ir:block-preds (ir:block-of f label)))]
                   #:when (hash-ref idom p #f))
          p))
      (unless (null? preds)
        (define new (for/fold ([new (car preds)]) ([p (in-list (cdr preds))]) (intersect p new)))
        (unless (equal? (hash-ref idom label #f) new)
          (hash-set! idom label new)
          (set! changed #t))))
    (when changed (settle)))

  (define children (make-hash))
  (for ([label (in-list order)]) (hash-set! children label '()))
  (for ([label (in-list order)])
    (define parent (hash-ref idom label))
    (unless (equal? parent label)
      (hash-set! children parent (append (hash-ref children parent) (list label)))))

  (define frontier (make-hash))
  (for ([label (in-list order)]) (hash-set! frontier label (make-hash)))
  (for ([label (in-list order)])
    (define b (ir:block-of f label))
    (when (>= (length (ir:block-preds b)) 2)
      (for ([pred (in-list (ir:block-preds b))])
        (let climb ([runner pred])
          (when (and (not (equal? runner (hash-ref idom label))) (hash-ref idom runner #f))
            (hash-set! (hash-ref frontier runner) label #t)
            (climb (hash-ref idom runner)))))))
  (dominance idom children frontier order))

;; -- where each register is written ------------------------------------------

;; A register written twice in one block is as much a variable as one written in
;; two blocks, so the count is what decides, and the blocks are what the frontier
;; walk needs.
(struct defs (blocks count) #:transparent)

(define (variables d)
  (sort (for/list ([(r n) (in-hash (defs-count d))] #:when (> n 1)) r) <))

(define (definitions f)
  (define blocks (make-hash))
  (define count (make-hash))
  (define (note! r label)
    (hash-set! (hash-ref! blocks r make-hash) label #t)
    (hash-update! count r add1 0))
  (for* ([b (in-list (ir:walk f))] [i (in-list (ir:instrs b))])
    (define r (ir:defs i))
    (when r (note! r (ir:block-label b))))
  (for ([p (in-gvector (ir:func-params f))]) (note! p (ir:func-entry f)))
  (defs blocks count))

;; -- placing --------------------------------------------------------------

;; A phi for `v` at every dominance frontier of a block defining `v`.  What each
;; block's phis are for is kept beside them: the renamer needs the variable, and
;; the phi itself only remembers what it was renamed to.
(define (place-phis! f dom d)
  (define sites (defs-blocks d))
  (define phi-vars (make-hash))
  (for ([label (in-list (ir:order-list f))]) (hash-set! phi-vars label '()))
  (for ([v (in-list (variables d))])
    (define placed (make-hash))
    (let loop ([work (sorted-labels (hash-ref sites v))])
      (unless (null? work)
        (define b (last work))
        (define rest (drop-right work 1))
        (set! work rest)
        (define added
          (for/list ([target (in-list (sorted-labels (hash-ref (dominance-frontier dom) b)))]
                     #:unless (hash-ref placed target #f))
            (hash-set! placed target #t)
            (hash-set! phi-vars target (append (hash-ref phi-vars target) (list v)))
            (define block (ir:block-of f target))
            (ir:set-block-phis!
             block
             (append (ir:block-phis block)
                     (list (ir:phi v (for/list ([p (in-list (ir:block-preds block))])
                                       (cons p v))))))
            target))
        (loop (append rest
                      (for/list ([target (in-list added)]
                                 #:unless (hash-ref (hash-ref sites v) target #f))
                        target))))))
  phi-vars)

;; -- renaming ----------------------------------------------------------------

;; `stacks` is the reaching definition of each variable, `undefined` the register
;; a variable read on a path that never wrote it reads from.
(struct renamer (func dom phi-vars variables stacks undefined order) #:transparent)

(define (new-renamer f dom phi-vars vars)
  (define set (make-hash))
  (for ([v (in-list vars)]) (hash-set! set v #t))
  (renamer f dom phi-vars set (make-hash) (make-hash) (box '())))

(define (variable? re v) (hash-ref (renamer-variables re) v #f))

(define (undef! re v)
  (or (hash-ref (renamer-undefined re) v #f)
      (let ([r (ir:new-reg! (renamer-func re))])
        (hash-set! (renamer-undefined re) v r)
        (set-box! (renamer-order re) (append (unbox (renamer-order re)) (list v)))
        r)))

(define (top re v)
  (define stack (hash-ref (renamer-stacks re) v '()))
  (if (null? stack) (undef! re v) (car stack)))

(define (rename! re v)
  (define fresh (ir:new-reg! (renamer-func re)))
  (hash-set! (renamer-stacks re) v (cons fresh (hash-ref (renamer-stacks re) v '())))
  fresh)

(define (pop! re v)
  (hash-set! (renamer-stacks re) v (cdr (hash-ref (renamer-stacks re) v))))

;; A variable read before it was ever written reads zero, and the zeros go in
;; front of the entry block.
(define (plant-undefined! re)
  (define entry (ir:block-of (renamer-func re) (ir:func-entry (renamer-func re))))
  (for ([v (in-list (unbox (renamer-order re)))])
    (ir:set-instrs! entry (cons (ir:i:const (hash-ref (renamer-undefined re) v) 0)
                                (ir:instrs entry)))))

(define (rename-block! re label)
  (define f (renamer-func re))
  (define block (ir:block-of f label))
  (define mine '())
  (define vars (hash-ref (renamer-phi-vars re) label))
  (ir:set-block-phis!
   block
   (for/list ([p (in-list (ir:block-phis block))] [v (in-list vars)])
     (set! mine (cons v mine))
     (ir:phi (rename! re v) (ir:phi-args p))))
  (ir:map-instrs!
   block
   (λ (i)
     (define renamed (ir:map-uses i (λ (r) (if (variable? re r) (top re r) r))))
     (define d (ir:defs renamed))
     (cond
       [(and d (variable? re d))
        (set! mine (cons d mine))
        (ir:with-def (rename! re d) renamed)]
       [else renamed])))
  (for ([succ (in-list (ir:succs block))])
    (define target (ir:block-of f succ))
    (define theirs (hash-ref (renamer-phi-vars re) succ))
    (ir:set-block-phis!
     target
     (for/list ([p (in-list (ir:block-phis target))] [v (in-list theirs)])
       (ir:phi-set-arg label (top re v) p))))
  mine)

;; The dominator tree, walked with an explicit stack so that what a block pushed
;; comes off again when its subtree is done.
(define (run-renamer! re)
  (define pushed (make-hash))
  (let loop ([work (list (cons (ir:func-entry (renamer-func re)) #f))])
    (unless (null? work)
      (define head (car work))
      (define rest (cdr work))
      (cond
        [(cdr head)
         (for ([v (in-list (hash-ref pushed (car head)))]) (pop! re v))
         (loop rest)]
        [else
         (define label (car head))
         (hash-set! pushed label (rename-block! re label))
         (loop (append (for/list ([child (in-list (hash-ref (dominance-children (renamer-dom re))
                                                            label))])
                         (cons child #f))
                       (list (cons label #t))
                       rest))]))))

;; -- the passes --------------------------------------------------------------

(define (construct! f)
  (ir:recompute-preds! f)
  (define dom (dominance-of f))
  (define d (definitions f))
  (define phi-vars (place-phis! f dom d))
  (define re (new-renamer f dom phi-vars (variables d)))
  (for ([at (in-range (gvector-count (ir:func-params f)))])
    (define p (gvector-ref (ir:func-params f) at))
    (when (variable? re p) (gvector-set! (ir:func-params f) at (rename! re p))))
  (run-renamer! re)
  (plant-undefined! re))

(define (construct-module! m)
  (for ([f (in-list (ir:module*-funcs m))]) (construct! f)))

;; Give every phi a place to put its copy in.
;;
;; An edge from a block with several successors into a block with several
;; predecessors has nowhere to hold the copies a phi turns into, so it gets a
;; block of its own.  The same goes for any edge into a block that still has a
;; phi, so that the emitter only ever has to put copies before a `jmp`.
(define (split-critical-edges! f)
  (for ([label (in-list (ir:order-list f))])
    (define b (ir:block-of f label))
    (when (>= (length (ir:succs b)) 2)
      (for ([succ (in-list (ir:succs b))])
        (define target (ir:block-of f succ))
        (unless (and (< (length (ir:block-preds target)) 2) (null? (ir:block-phis target)))
          (define split (ir:add-block! f (format "~a.~a" label succ)))
          (ir:emit! split (ir:i:jmp succ))
          (define at (sub1 (ir:count b)))
          (ir:set-instrs! b (append (take (ir:instrs b) at)
                                    (list (ir:rename-target succ (ir:block-label split)
                                                            (ir:terminator b)))))
          (ir:map-phis!
           target
           (λ (p)
             (define taken (ir:phi-remove-arg label p))
             (if taken (ir:phi-set-arg (ir:block-label split) (car taken) (cdr taken)) p)))))))
  (ir:recompute-preds! f))

;; -- what SSA promises -------------------------------------------------------

(define (verify f)
  (define dom (dominance-of f))
  (define definition (make-hash))
  (define (define! r where)
    (when (hash-ref definition r #f) (error 'ssa "%~a is defined twice" r))
    (hash-set! definition r where))
  (for ([b (in-list (ir:walk f))])
    (for ([p (in-list (ir:block-phis b))]) (define! (ir:phi-dst p) (ir:block-label b)))
    (for ([i (in-list (ir:instrs b))])
      (define d (ir:defs i))
      (when d (define! d (ir:block-label b)))))
  (for ([p (in-gvector (ir:func-params f))])
    (unless (hash-ref definition p #f) (hash-set! definition p (ir:func-entry f))))
  (define (reaches r where what)
    (define at (hash-ref definition r #f))
    (unless at (error 'ssa "%~a is never defined" r))
    (unless (dominates? dom at where) (error 'ssa "%~a does not reach ~a" r what)))
  (for ([b (in-list (ir:walk f))])
    (for ([p (in-list (ir:block-phis b))])
      (unless (equal? (sort (ir:phi-preds p) label<?) (sort (ir:block-preds b) label<?))
        (error 'ssa "the phi in ~a does not name its predecessors" (ir:block-label b)))
      (for ([a (in-list (ir:phi-args p))])
        (reaches (cdr a) (car a)
                 (format "~a through ~a" (ir:block-label b) (car a)))))
    (for* ([i (in-list (ir:instrs b))] [r (in-list (ir:uses i))])
      (reaches r (ir:block-label b)
               (format "its use in ~a" (ir:block-label b))))))

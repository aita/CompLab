;;; SSA construction, the textbook way.
;;;
;;; Dominators by the iterative algorithm of Cooper, Harvey and Kennedy,
;;; dominance frontiers from those, phis at the frontiers of every definition,
;;; and then one walk of the dominator tree renaming as it goes.  This is
;;; minimal SSA and nothing cleverer: a phi is placed wherever the frontier
;;; says, whether or not the variable is live there, and the dead ones leave in
;;; `opt.scm`.
;;;
;;; Only registers written more than once take part.  Everything lowering
;;; produced once — a temporary — is already in SSA and is left with its name.

(define-module (wolv ssa)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (last delete every))
  #:use-module (ice-9 format)
  #:use-module (wolv ir)
  #:export (<dominance> dominance-idom dominance-children dominance-frontier
            dominance-order dominates? dominance-of
            construct! construct-module! split-critical-edges! verify
            label<? sorted-labels))

;; Blocks are named, so every set of them is walked in name order, which is what
;; keeps two runs — and two implementations — placing phis identically.
(define (label<? a b) (string<? a b))
(define (sorted-labels h) (sort (hash-map->list (lambda (k v) k) h) label<?))

(define-class <dominance> ()
  (idom #:init-keyword #:idom #:getter dominance-idom)
  (children #:init-keyword #:children #:getter dominance-children)
  (frontier #:init-keyword #:frontier #:getter dominance-frontier)
  (order #:init-keyword #:order #:getter dominance-order))

(define (dominates? dom a b)
  (let loop ((b b))
    (cond
     ((equal? a b) #t)
     (else
      (let ((parent (hash-ref (dominance-idom dom) b)))
        (if (equal? parent b) #f (loop parent)))))))

(define (dominance-of f)
  (let* ((order (rpo f))
         (rank (make-hash-table))
         (idom (make-hash-table)))
    (let loop ((ls order) (i 0))
      (unless (null? ls) (hash-set! rank (car ls) i) (loop (cdr ls) (+ i 1))))
    (hash-set! idom (func-entry f) (func-entry f))

    ;; The two runners climb until they meet, each time from the deeper one.
    (define (intersect a b)
      (let loop ((a a) (b b))
        (cond
         ((equal? a b) a)
         (else
          (let* ((a* (let up ((a a))
                       (if (> (hash-ref rank a) (hash-ref rank b))
                           (up (hash-ref idom a)) a)))
                 (b* (let up ((b b))
                       (if (> (hash-ref rank b) (hash-ref rank a*))
                           (up (hash-ref idom b)) b))))
            (loop a* b*))))))

    (let settle ()
      (let ((changed #f))
        (for-each
         (lambda (label)
           (let ((preds (filter (lambda (p) (hash-ref idom p #f))
                                (block-preds (block-of f label)))))
             (unless (null? preds)
               (let ((new (fold-left-into intersect (car preds) (cdr preds))))
                 (unless (equal? (hash-ref idom label #f) new)
                   (hash-set! idom label new)
                   (set! changed #t))))))
         (if (null? order) '() (cdr order)))
        (when changed (settle))))

    (let ((children (make-hash-table))
          (frontier (make-hash-table)))
      (for-each (lambda (label) (hash-set! children label '())) order)
      (for-each (lambda (label)
                  (let ((parent (hash-ref idom label)))
                    (unless (equal? parent label)
                      (hash-set! children parent
                                 (append (hash-ref children parent) (list label))))))
                order)
      (for-each (lambda (label) (hash-set! frontier label (make-hash-table))) order)
      (for-each
       (lambda (label)
         (let ((b (block-of f label)))
           (when (>= (length (block-preds b)) 2)
             (for-each
              (lambda (pred)
                (let climb ((runner pred))
                  (when (and (not (equal? runner (hash-ref idom label)))
                             (hash-ref idom runner #f))
                    (hash-set! (hash-ref frontier runner) label #t)
                    (climb (hash-ref idom runner)))))
              (block-preds b)))))
       order)
      (make <dominance> #:idom idom #:children children
            #:frontier frontier #:order order))))

;; `(fold-left-into f seed rest)` is `for/fold` with the accumulator second,
;; which is the order `intersect` is written in.
(define (fold-left-into f seed rest)
  (let loop ((acc seed) (xs rest))
    (if (null? xs) acc (loop (f (car xs) acc) (cdr xs)))))

;; -- where each register is written ------------------------------------------

;; A register written twice in one block is as much a variable as one written in
;; two blocks, so the count is what decides, and the blocks are what the
;; frontier walk needs.
(define-class <defsites> ()
  (blocks #:init-keyword #:blocks #:getter defsites-blocks)
  (count #:init-keyword #:count #:getter defsites-count))

(define (variables d)
  (sort (hash-fold (lambda (r n acc) (if (> n 1) (cons r acc) acc))
                   '() (defsites-count d))
        <))

(define (definitions f)
  (let ((blocks (make-hash-table))
        (count (make-hash-table)))
    (define (note! r label)
      (let ((where (or (hash-ref blocks r #f)
                       (let ((h (make-hash-table))) (hash-set! blocks r h) h))))
        (hash-set! where label #t))
      (hash-set! count r (+ 1 (hash-ref count r 0))))
    (for-each (lambda (b)
                (for-each (lambda (i)
                            (let ((r (defs i)))
                              (when r (note! r (block-label b)))))
                          (instrs b)))
              (walk f))
    (for-each (lambda (p) (note! p (func-entry f))) (func-params f))
    (make <defsites> #:blocks blocks #:count count)))

;; -- placing -----------------------------------------------------------------

;; A phi for `v` at every dominance frontier of a block defining `v`.  What each
;; block's phis are for is kept beside them: the renamer needs the variable, and
;; the phi itself only remembers what it was renamed to.
(define (place-phis! f dom d)
  (let ((sites (defsites-blocks d))
        (phi-vars (make-hash-table)))
    (for-each (lambda (label) (hash-set! phi-vars label '())) (order-list f))
    (for-each
     (lambda (v)
       (let ((placed (make-hash-table)))
         (let loop ((work (sorted-labels (hash-ref sites v))))
           (unless (null? work)
             (let* ((b (last work))
                    (rest (list-head work (- (length work) 1)))
                    (added '()))
               (for-each
                (lambda (target)
                  (unless (hash-ref placed target #f)
                    (hash-set! placed target #t)
                    (hash-set! phi-vars target
                               (append (hash-ref phi-vars target) (list v)))
                    (let ((block (block-of f target)))
                      (set-block-phis!
                       block
                       (append (block-phis block)
                               (list (phi v (map (lambda (p) (cons p v))
                                                 (block-preds block)))))))
                    (set! added (append added (list target)))))
                (sorted-labels (hash-ref (dominance-frontier dom) b)))
               (loop (append rest
                             (filter (lambda (target)
                                       (not (hash-ref (hash-ref sites v) target #f)))
                                     added))))))))
     (variables d))
    phi-vars))

;; -- renaming ----------------------------------------------------------------

;; `stacks` is the reaching definition of each variable, `undefined` the register
;; a variable read on a path that never wrote it reads from.
(define-class <renamer> ()
  (func #:init-keyword #:func #:getter renamer-func)
  (dom #:init-keyword #:dom #:getter renamer-dom)
  (phi-vars #:init-keyword #:phi-vars #:getter renamer-phi-vars)
  (variables #:init-keyword #:variables #:getter renamer-variables)
  (stacks #:init-thunk make-hash-table #:getter renamer-stacks)
  (undefined #:init-thunk make-hash-table #:getter renamer-undefined)
  (order #:init-value '() #:accessor renamer-order))

(define (new-renamer f dom phi-vars vars)
  (let ((set (make-hash-table)))
    (for-each (lambda (v) (hash-set! set v #t)) vars)
    (make <renamer> #:func f #:dom dom #:phi-vars phi-vars #:variables set)))

(define (variable? re v) (hash-ref (renamer-variables re) v #f))

(define (undef! re v)
  (or (hash-ref (renamer-undefined re) v #f)
      (let ((r (new-reg! (renamer-func re))))
        (hash-set! (renamer-undefined re) v r)
        (set! (renamer-order re) (append (renamer-order re) (list v)))
        r)))

(define (top re v)
  (let ((stack (hash-ref (renamer-stacks re) v '())))
    (if (null? stack) (undef! re v) (car stack))))

(define (rename! re v)
  (let ((fresh (new-reg! (renamer-func re))))
    (hash-set! (renamer-stacks re) v
               (cons fresh (hash-ref (renamer-stacks re) v '())))
    fresh))

(define (pop-name! re v)
  (hash-set! (renamer-stacks re) v (cdr (hash-ref (renamer-stacks re) v))))

;; A variable read before it was ever written reads zero, and the zeros go in
;; front of the entry block.
(define (plant-undefined! re)
  (let ((entry (block-of (renamer-func re) (func-entry (renamer-func re)))))
    (for-each (lambda (v)
                (set-instrs! entry
                             (cons (i-const (hash-ref (renamer-undefined re) v) 0)
                                   (instrs entry))))
              (renamer-order re))))

(define (rename-block! re label)
  (let* ((f (renamer-func re))
         (block (block-of f label))
         (mine '())
         (vars (hash-ref (renamer-phi-vars re) label)))
    (set-block-phis!
     block
     (let loop ((ps (block-phis block)) (vs vars) (acc '()))
       (if (null? ps)
           (reverse acc)
           (begin
             (set! mine (cons (car vs) mine))
             (loop (cdr ps) (cdr vs)
                   (cons (phi (rename! re (car vs)) (phi-args (car ps))) acc))))))
    (map-instrs!
     block
     (lambda (i)
       (let* ((renamed (map-uses i (lambda (r) (if (variable? re r) (top re r) r))))
              (d (defs renamed)))
         (cond
          ((and d (variable? re d))
           (set! mine (cons d mine))
           (with-def renamed (rename! re d)))
          (else renamed)))))
    (for-each
     (lambda (succ)
       (let ((target (block-of f succ))
             (theirs (hash-ref (renamer-phi-vars re) succ)))
         (set-block-phis!
          target
          (let loop ((ps (block-phis target)) (vs theirs) (acc '()))
            (if (null? ps)
                (reverse acc)
                (loop (cdr ps) (cdr vs)
                      (cons (phi-set-arg label (top re (car vs)) (car ps)) acc)))))))
     (succs block))
    mine))

;; The dominator tree, walked with an explicit stack so that what a block pushed
;; comes off again when its subtree is done.
(define (run-renamer! re)
  (let ((pushed (make-hash-table)))
    (let loop ((work (list (cons (func-entry (renamer-func re)) #f))))
      (unless (null? work)
        (let ((head (car work))
              (rest (cdr work)))
          (cond
           ((cdr head)
            (for-each (lambda (v) (pop-name! re v)) (hash-ref pushed (car head)))
            (loop rest))
           (else
            (let ((label (car head)))
              (hash-set! pushed label (rename-block! re label))
              (loop (append (map (lambda (child) (cons child #f))
                                 (hash-ref (dominance-children (renamer-dom re)) label))
                            (list (cons label #t))
                            rest))))))))))

;; -- the passes --------------------------------------------------------------

(define (construct! f)
  (recompute-preds! f)
  (let* ((dom (dominance-of f))
         (d (definitions f))
         (phi-vars (place-phis! f dom d))
         (re (new-renamer f dom phi-vars (variables d))))
    (set-func-params! f (map-in-order (lambda (p) (if (variable? re p) (rename! re p) p))
                                      (func-params f)))
    (run-renamer! re)
    (plant-undefined! re)))

(define (construct-module! m) (for-each construct! (module-funcs m)))

;; Give every phi a place to put its copy in.
;;
;; An edge from a block with several successors into a block with several
;; predecessors has nowhere to hold the copies a phi turns into, so it gets a
;; block of its own.  The same goes for any edge into a block that still has a
;; phi, so that the emitter only ever has to put copies before a `jmp`.
(define (split-critical-edges! f)
  (for-each
   (lambda (label)
     (let ((b (block-of f label)))
       (when (>= (length (succs b)) 2)
         (for-each
          (lambda (succ)
            (let ((target (block-of f succ)))
              (unless (and (< (length (block-preds target)) 2)
                           (null? (block-phis target)))
                (let ((split (add-block! f (format #f "~a.~a" label succ))))
                  (emit! split (i-jmp succ))
                  (let ((at (- (count b) 1)))
                    (set-instrs! b (append (list-head (instrs b) at)
                                           (list (rename-target (terminator b) succ
                                                                (block-label split))))))
                  (map-phis!
                   target
                   (lambda (p)
                     (let ((taken (phi-remove-arg label p)))
                       (if taken
                           (phi-set-arg (block-label split) (car taken) (cdr taken))
                           p))))))))
          (succs b)))))
   (order-list f))
  (recompute-preds! f))

;; -- what SSA promises -------------------------------------------------------

(define (verify f)
  (let ((dom (dominance-of f))
        (definition (make-hash-table)))
    (define (define! r where)
      (when (hash-ref definition r #f) (error "%~a is defined twice" r))
      (hash-set! definition r where))
    (for-each
     (lambda (b)
       (for-each (lambda (p) (define! (phi-dst p) (block-label b))) (block-phis b))
       (for-each (lambda (i)
                   (let ((d (defs i)))
                     (when d (define! d (block-label b)))))
                 (instrs b)))
     (walk f))
    (for-each (lambda (p)
                (unless (hash-ref definition p #f)
                  (hash-set! definition p (func-entry f))))
              (func-params f))
    (define (reaches r where what)
      (let ((at (hash-ref definition r #f)))
        (unless at (error (format #f "%~a is never defined" r)))
        (unless (dominates? dom at where)
          (error (format #f "%~a does not reach ~a" r what)))))
    (for-each
     (lambda (b)
       (for-each
        (lambda (p)
          (unless (equal? (sort (phi-preds p) label<?) (sort (block-preds b) label<?))
            (error (format #f "the phi in ~a does not name its predecessors"
                           (block-label b))))
          (for-each (lambda (a)
                      (reaches (cdr a) (car a)
                               (format #f "~a through ~a" (block-label b) (car a))))
                    (phi-args p)))
        (block-phis b))
       (for-each (lambda (i)
                   (for-each (lambda (r)
                               (reaches r (block-label b)
                                        (format #f "its use in ~a" (block-label b))))
                             (uses i)))
                 (instrs b)))
     (walk f))))

#lang racket/base

;; Doing several copies at once, one at a time.
;;
;; A phi is a copy that happens on an edge, and all the phis of a block happen
;; together: every argument is read before any destination is written.  Once the
;; allocator has given both ends real registers that is a permutation, and
;; putting a permutation into a sequence of instructions is this module.
;;
;; Copies whose destination nobody else has still to read can go first.  When
;; only cycles are left, something has to be got out of the way, and there are
;; two ways to do it: a register the function never used can hold a value for one
;; step, and if there is no such register the two ends of the cycle swap.  A swap
;; is three `eor`s and needs nothing to borrow, which is why no register is
;; reserved for this anywhere in the compiler.

(require racket/list)

(provide (struct-out mov) (struct-out swap) sequentialize)

(struct mov (dst src) #:transparent)
(struct swap (a b) #:transparent)

;; Order `(destination . source)` pairs so that nothing is lost on the way.
;; `borrowed` is a register free to clobber, or #f.
(define (sequentialize moves borrowed)
  (define real (for/list ([m (in-list moves)] #:unless (eqv? (car m) (cdr m))) m))
  (unless (= (length (remove-duplicates (map car real))) (length real))
    (error 'copies "a parallel copy writes a register twice"))
  ;; `pending` stays in the order it was given: which copy is picked when several
  ;; are ready is what the emitted sequence looks like.
  (let loop ([pending real] [done '()])
    (cond
      [(null? pending) (reverse done)]
      [else
       (define sources (map cdr pending))
       (define ready (for/list ([m (in-list pending)] #:unless (memv (car m) sources)) (car m)))
       (cond
         [(pair? ready)
          (loop (for/list ([m (in-list pending)] #:unless (memv (car m) ready)) m)
                (append (for/list ([dst (in-list (reverse ready))])
                          (mov dst (cdr (assv dst pending))))
                        done))]
         [borrowed
          (define stuck (car (first pending)))
          (loop (moved pending stuck borrowed) (cons (mov borrowed stuck) done))]
         [else
          ;; Swapping satisfies `stuck` outright and leaves its old value where
          ;; the other end was, so everything still to read it reads there.
          (define stuck (car (first pending)))
          (define other (cdr (first pending)))
          (loop (moved (rest pending) stuck other) (cons (swap stuck other) done))])])))

;; The value that was in `was` is in `now`; whoever wanted it looks there.
(define (moved pending was now)
  (for/list ([m (in-list pending)]
             ;; The swap already put it where it belongs.
             #:unless (and (eqv? (cdr m) was) (eqv? (car m) now)))
    (if (eqv? (cdr m) was) (cons (car m) now) m)))

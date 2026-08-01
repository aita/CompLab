#lang racket/base

;; Leaving SSA before allocation.
;;
;; A phi is a copy that happens on an edge, so it becomes copies at the end of
;; each predecessor.  Critical edges are already split, so a predecessor of a
;; block with phis has nowhere else to go and the copies can simply be appended.
;;
;; The copies of one edge happen at once: every argument is read before any
;; destination is written.  Usually that needs no care, because a phi's
;; destination is defined nowhere else and so is nobody's argument — but a block
;; that is its own predecessor can have two phis that swap, and then the copies
;; go through temporaries, which is Sreedhar's answer and which coalescing is
;; expected to remove again.

(require racket/list
         racket/set
         (prefix-in ir: "ir.rkt"))

(provide destruct! destruct-module!)

;; Replace every phi in `f` with copies in its predecessors.
(define (destruct! f)
  (for ([b (in-list (ir:walk f))] #:unless (null? (ir:block-phis b)))
    (for ([pred (in-list (ir:block-preds b))])
      (define source (ir:block-of f pred))
      (unless (= (length (ir:succs source)) 1)
        (error 'outofssa "~a -> ~a is a critical edge" pred (ir:block-label b)))
      (copy-in-parallel! f source
                         (for/list ([p (in-list (ir:block-phis b))])
                           (cons (ir:phi-dst p) (cdr (ir:phi-arg p pred))))))
    (ir:set-block-phis! b '()))
  (ir:recompute-preds! f))

(define (destruct-module! m) (for ([f (in-list (ir:module*-funcs m))]) (destruct! f)))

(define (copy-in-parallel! f b moves)
  (define real (for/list ([m (in-list moves)] #:unless (eqv? (car m) (cdr m))) m))
  (unless (null? real)
    (define written (for/seteqv ([m (in-list real)]) (car m)))
    (define copies
      (cond
        ;; Something read is also written, so the two halves cannot be one list.
        [(for/or ([r (in-list (map cdr real))]) (set-member? written r))
         (define through
           (for/hasheqv ([m (in-list real)]) (values (car m) (ir:new-reg! f))))
         (append (for/list ([m (in-list real)])
                   (ir:i:move (hash-ref through (car m)) (cdr m)))
                 (for/list ([m (in-list real)])
                   (ir:i:move (car m) (hash-ref through (car m)))))]
        [else (for/list ([m (in-list real)]) (ir:i:move (car m) (cdr m)))]))
    (define at (sub1 (ir:count b)))
    (ir:set-instrs! b (append (take (ir:instrs b) at) copies (drop (ir:instrs b) at)))))

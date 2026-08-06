;;; Spilling.
;;;
;;; A spilled value gets a frame slot, a store after every definition of it and
;;; a reload in front of every use.  The reloads are new registers, live from
;;; the load to the instruction under it and nowhere else, which is what makes
;;; the pressure come down.  Nothing here assumes SSA: a value written twice
;;; gets two stores, and a phi argument is reloaded at the end of the
;;; predecessor it comes from, so the same rewrite serves the graph before and
;;; after it left SSA.

(define-module (wolv spill)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (any))
  #:use-module (ice-9 format)
  #:use-module (wolv ir)
  #:use-module (wolv ssa)
  #:use-module (wolv regset)
  #:export (out-of-registers out-of-registers? out-of-registers-message
            loop-depth costs spill!))

;; Thrown when spilling cannot help either.
(define (out-of-registers message) (throw 'wolv-out-of-registers message))

(define (out-of-registers? key) (eq? key 'wolv-out-of-registers))
(define (out-of-registers-message message) message)

;; How deeply each block is nested in loops, for weighing what a use costs.
;;
;; A back edge is an edge into a block that dominates its source; everything
;; that can reach the source without leaving the dominated region is in that
;; loop.
(define (loop-depth f)
  (let ((dom (dominance-of f))
        (depth (make-hash-table)))
    (for-each (lambda (label) (hash-set! depth label 0)) (order-list f))
    (for-each
     (lambda (b)
       (for-each
        (lambda (succ)
          (when (dominates? dom succ (block-label b))
            (let ((body (make-hash-table)))
              (hash-set! body succ #t)
              (let walk-back ((stack (list (block-label b))))
                (unless (null? stack)
                  (let ((label (car stack)))
                    (cond
                     ((hash-ref body label #f) (walk-back (cdr stack)))
                     (else
                      (hash-set! body label #t)
                      (walk-back (append (reverse (block-preds (block-of f label)))
                                         (cdr stack))))))))
              (hash-for-each (lambda (label _)
                               (hash-set! depth label (+ 1 (hash-ref depth label 0))))
                             body))))
        (succs b)))
     (walk f))
    depth))

;; What spilling a value would cost: its reads and writes, weighed by loops.
(define (costs f)
  (let ((depth (loop-depth f))
        (weight (make-hash-table)))
    (define (weigh! r by) (hash-set! weight r (+ (hash-ref weight r 0.0) by)))
    (for-each
     (lambda (b)
       (let ((scale (exact->inexact
                     (expt 10 (min (hash-ref depth (block-label b)) 4)))))
         (for-each
          (lambda (p)
            (for-each (lambda (a)
                        (weigh! (cdr a)
                                (exact->inexact
                                 (expt 10 (min (hash-ref depth (car a)) 4)))))
                      (phi-args p))
            (weigh! (phi-dst p) scale))
          (block-phis b))
         (for-each
          (lambda (i)
            (for-each (lambda (r) (weigh! r scale)) (uses i))
            (let ((d (defs i)))
              (when d (weigh! d scale))))
          (instrs b))))
     (walk f))
    weight))

;; Give `victim` a frame slot, and answer with the reloads that replaced it.
(define (spill! f victim slots)
  (let ((slot (new-slot! f))
        (reloads '()))
    (hash-set! slots victim slot)
    (let ((param? (and (memv victim (func-params f)) #t)))
      (for-each
       (lambda (b)
         (when (any (lambda (p) (eqv? (phi-dst p) victim)) (block-phis b))
           (set-instrs! b (cons (i-store-slot slot victim) (instrs b))))
         (when (and param? (equal? (block-label b) (func-entry f)))
           (set-instrs! b (cons (i-store-slot slot victim) (instrs b))))
         (set-instrs!
          b
          (append-map-in-order
           (lambda (i)
             ;; The store this pass just put in reads the victim on purpose.
             (let* ((store? (and (is-a? i <i-store-slot>)
                                 (= (i-store-slot-slot i) slot)))
                    (reads? (and (not store?) (memv victim (uses i))))
                    (fresh (and reads? (new-reg! f))))
               (when fresh (set! reloads (cons fresh reloads)))
               (let ((rewritten
                      (if fresh
                          (map-uses i (lambda (r) (if (eqv? r victim) fresh r)))
                          i)))
                 (append (if fresh (list (i-load-slot fresh slot)) '())
                         (list rewritten)
                         (if (eqv? (defs i) victim)
                             (list (i-store-slot slot victim))
                             '())))))
           (instrs b))))
       (walk f)))

    (for-each
     (lambda (b)
       (map-phis!
        b
        (lambda (p)
          (let loop ((args (phi-args p)) (p p))
            (cond
             ((null? args) p)
             ((eqv? (cdr (car args)) victim)
              (let* ((source (block-of f (car (car args))))
                     (fresh (new-reg! f))
                     (at (- (count source) 1)))
                (set! reloads (cons fresh reloads))
                (set-instrs! source (append (list-head (instrs source) at)
                                            (list (i-load-slot fresh slot))
                                            (list-tail (instrs source) at)))
                (loop (cdr args) (phi-set-arg (car (car args)) fresh p))))
             (else (loop (cdr args) p)))))))
     (walk f))
    (regset-of-list reloads)))

(define (append-map-in-order f xs)
  (let loop ((xs xs) (acc '()))
    (if (null? xs)
        (apply append (reverse acc))
        (loop (cdr xs) (cons (f (car xs)) acc)))))

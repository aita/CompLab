;;; Doing several copies at once, one at a time.
;;;
;;; A phi is a copy that happens on an edge, and all the phis of a block happen
;;; together: every argument is read before any destination is written.  Once
;;; the allocator has given both ends real registers that is a permutation, and
;;; putting a permutation into a sequence of instructions is this module.
;;;
;;; Copies whose destination nobody else has still to read can go first.  When
;;; only cycles are left, something has to be got out of the way, and there are
;;; two ways to do it: a register the function never used can hold a value for
;;; one step, and if there is no such register the two ends of the cycle swap.
;;; A swap is three `eor`s and needs nothing to borrow, which is why no register
;;; is reserved for this anywhere in the compiler.

(define-module (wolv copies)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (delete-duplicates))
  #:export (<mov> mov mov? mov-dst mov-src
            <swap> swap swap? swap-a swap-b
            sequentialize))

(define-class <mov> ()
  (dst #:init-keyword #:dst #:getter mov-dst)
  (src #:init-keyword #:src #:getter mov-src))

(define-class <swap> ()
  (a #:init-keyword #:a #:getter swap-a)
  (b #:init-keyword #:b #:getter swap-b))

(define (mov dst src) (make <mov> #:dst dst #:src src))
(define (swap a b) (make <swap> #:a a #:b b))
(define (mov? x) (is-a? x <mov>))
(define (swap? x) (is-a? x <swap>))

;; Order `(destination . source)` pairs so that nothing is lost on the way.
;; `borrowed` is a register free to clobber, or #f.
(define (sequentialize moves borrowed)
  (let ((real (filter (lambda (m) (not (eqv? (car m) (cdr m)))) moves)))
    (unless (= (length (delete-duplicates (map car real))) (length real))
      (error "a parallel copy writes a register twice"))
    ;; `pending` stays in the order it was given: which copy is picked when
    ;; several are ready is what the emitted sequence looks like.
    (let loop ((pending real) (done '()))
      (cond
       ((null? pending) (reverse done))
       (else
        (let* ((sources (map cdr pending))
               (ready (filter (lambda (dst) (not (memv dst sources)))
                              (map car pending))))
          (cond
           ((pair? ready)
            (loop (filter (lambda (m) (not (memv (car m) ready))) pending)
                  (append (map (lambda (dst) (mov dst (cdr (assv dst pending))))
                               (reverse ready))
                          done)))
           (borrowed
            (let ((stuck (car (car pending))))
              (loop (moved pending stuck borrowed) (cons (mov borrowed stuck) done))))
           (else
            ;; Swapping satisfies `stuck` outright and leaves its old value
            ;; where the other end was, so everything still to read it reads
            ;; there.
            (let ((stuck (car (car pending)))
                  (other (cdr (car pending))))
              (loop (moved (cdr pending) stuck other)
                    (cons (swap stuck other) done)))))))))))

;; The value that was in `was` is in `now`; whoever wanted it looks there.
(define (moved pending was now)
  (map (lambda (m) (if (eqv? (cdr m) was) (cons (car m) now) m))
       ;; The swap already put it where it belongs.
       (filter (lambda (m) (not (and (eqv? (cdr m) was) (eqv? (car m) now)))) pending)))

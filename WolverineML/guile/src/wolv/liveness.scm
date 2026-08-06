;;; Liveness on SSA.
;;;
;;; The only subtlety is the phi.  A phi does not read its arguments where it
;;; stands; it reads them on the edges, so an argument is live at the end of the
;;; predecessor it is paired with and not anywhere inside the block that holds
;;; the phi.  Getting that wrong is what makes phi-related values interfere when
;;; they should not.

(define-module (wolv liveness)
  #:use-module (oop goops)
  #:use-module (wolv ir)
  #:use-module (wolv regset)
  #:export (<liveness> analyse live-in live-out across-calls pressure))

(define-class <liveness> ()
  (in #:init-keyword #:in #:getter liveness-in)
  (out #:init-keyword #:out #:getter liveness-out))

(define (live-in l label) (hash-ref (liveness-in l) label))
(define (live-out l label) (hash-ref (liveness-out l) label))

(define (analyse f)
  ;; What a block reads before writing, and what it writes at all.
  (let ((upward (make-hash-table))
        (killed (make-hash-table))
        (in (make-hash-table))
        (out (make-hash-table)))
    (for-each
     (lambda (b)
       (let ((kill (regset-of-list (map phi-dst (block-phis b))))
             (use regset-empty))
         (for-each
          (lambda (i)
            (for-each (lambda (r)
                        (unless (regset-member? kill r) (set! use (regset-add use r))))
                      (uses i))
            (let ((d (defs i)))
              (when d (set! kill (regset-add kill d)))))
          (instrs b))
         (hash-set! upward (block-label b) use)
         (hash-set! killed (block-label b) kill)))
     (walk f))

    (for-each (lambda (label)
                (hash-set! in label regset-empty)
                (hash-set! out label regset-empty))
              (order-list f))

    (let ((order (reverse (rpo f))))
      (let settle ()
        (let ((changed #f))
          (for-each
           (lambda (label)
             (let* ((b (block-of f label))
                    (leaving
                     (let loop ((ss (succs b)) (acc regset-empty))
                       (if (null? ss)
                           acc
                           (loop (cdr ss)
                                 (let inner ((ps (block-phis (block-of f (car ss))))
                                             (acc (regset-union acc (hash-ref in (car ss)))))
                                   (if (null? ps)
                                       acc
                                       (let ((arg (phi-arg (car ps) label)))
                                         (inner (cdr ps)
                                                (if arg (regset-add acc (cdr arg)) acc)))))))))
                    (entering (regset-union (hash-ref upward label)
                                            (regset-subtract leaving (hash-ref killed label)))))
               (unless (and (equal? leaving (hash-ref out label))
                            (equal? entering (hash-ref in label)))
                 (hash-set! out label leaving)
                 (hash-set! in label entering)
                 (set! changed #t))))
           order)
          (when changed (settle)))))
    (make <liveness> #:in in #:out out)))

;; Values that are live across a call, and so cannot sit in a scratch register.
(define (across-calls f l)
  (let loop ((bs (walk f)) (out regset-empty))
    (if (null? bs)
        out
        (let inner ((is (reverse (instrs (car bs))))
                    (after (live-out l (block-label (car bs))))
                    (out out))
          (if (null? is)
              (loop (cdr bs) out)
              (let* ((i (car is))
                     (d (defs i))
                     (without (if d (regset-remove after d) after)))
                (inner (cdr is)
                       (regset-union without (regset-of-list (uses i)))
                       (if (is-a? i <i-call>) (regset-union out without) out))))))))

;; The most values live at any one point — the registers the function wants.
(define (pressure f l)
  (let loop ((bs (walk f)) (most 0))
    (if (null? bs)
        most
        (let* ((b (car bs))
               (after0 (live-out l (block-label b)))
               (worst
                (let inner ((is (reverse (instrs b)))
                            (after after0)
                            (most (max most (regset-count after0))))
                  (if (null? is)
                      most
                      (let* ((i (car is))
                             (d (defs i))
                             (next (regset-union (if d (regset-remove after d) after)
                                                 (regset-of-list (uses i)))))
                        (inner (cdr is) next (max most (regset-count next)))))))
               (entry (let inner ((ps (block-phis b)) (acc (live-in l (block-label b))))
                        (if (null? ps)
                            acc
                            (inner (cdr ps) (regset-add acc (phi-dst (car ps))))))))
          (loop (cdr bs) (max worst (regset-count entry)))))))

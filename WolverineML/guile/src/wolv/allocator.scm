;;; The seam the allocator is reached through, and the verifier it answers to.
;;;
;;; There is one allocator here — leave SSA, build the interference graph,
;;; colour it with Chaitin's algorithm and George and Appel's iterated
;;; coalescing.  The Python tree has a second one that colours the SSA itself in
;;; dominance order, and keeps both so that the two can be measured against each
;;; other; this tree keeps the graph.
;;;
;;; What comes out is an `<allocation>` and not a slot of the function: a
;;; colouring is an assignment from the program's registers to the machine's,
;;; and nothing but the emitter and this verifier ever reads one.

(define-module (wolv allocator)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (wolv registers)
  #:use-module (wolv graph)
  #:use-module (wolv ir)
  #:use-module (wolv liveness)
  #:use-module (wolv regset)
  #:export (allocate-module verify verify-module))

(define* (allocate-module m #:optional (machine (whole-machine)))
  (let ((allocs (make-hash-table)))
    (for-each (lambda (f) (hash-set! allocs (func-label f) (allocate f machine)))
              (module-funcs m))
    allocs))

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
;; Every value that interferes with another is caught this way, because the
;; later of the two definitions that put the values there happens while the
;; other is live.
(define (verify f alloc)
  (let ((colours (allocation-colours alloc))
        (l (analyse f)))
    (define (coloured! r)
      (unless (hash-ref colours r #f)
        (error (format #f "%~a has no colour" r))))
    (define (no-clash alive written where)
      (let ((colour (hash-ref colours written #f)))
        (when colour
          (for-each
           (lambda (other)
             (when (and (not (eqv? other written))
                        (eqv? (hash-ref colours other #f) colour))
               (error (format #f "x~a holds %~a and %~a at once in ~a"
                              colour written other where))))
           (regset->list alive)))))
    (for-each
     (lambda (b)
       (let loop ((is (reverse (instrs b))) (alive (live-out l (block-label b))))
         (unless (null? is)
           (let* ((i (car is))
                  (after (if (is-a? i <i-move>)
                             (regset-remove alive (i-move-src i))
                             alive))
                  (d (defs i)))
             (for-each coloured! (uses i))
             (when d
               (coloured! d)
               (no-clash (regset-add after d) d (block-label b)))
             (loop (cdr is)
                   (regset-union (if d (regset-remove after d) after)
                                 (regset-of-list (uses i)))))))
       (let ((entering
              (let loop ((ps (block-phis b)) (entering (live-in l (block-label b))))
                (cond
                 ((null? ps) entering)
                 (else
                  (coloured! (phi-dst (car ps)))
                  (let ((with-phi (regset-add entering (phi-dst (car ps)))))
                    (no-clash with-phi (phi-dst (car ps)) (block-label b))
                    (loop (cdr ps) with-phi)))))))
         (when (equal? (block-label b) (func-entry f))
           (let loop ((params (func-params f)) (entering entering))
             (unless (null? params)
               (let ((with-param (regset-add entering (car params))))
                 (no-clash with-param (car params) (block-label b))
                 (loop (cdr params) with-param)))))))
     (walk f))))

(define (verify-module m allocs)
  (for-each (lambda (f) (verify f (hash-ref allocs (func-label f))))
            (module-funcs m)))

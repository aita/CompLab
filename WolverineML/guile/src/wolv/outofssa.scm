;;; Leaving SSA before allocation.
;;;
;;; A phi is a copy that happens on an edge, so it becomes copies at the end of
;;; each predecessor.  Critical edges are already split, so a predecessor of a
;;; block with phis has nowhere else to go and the copies can simply be
;;; appended.
;;;
;;; The copies of one edge happen at once: every argument is read before any
;;; destination is written.  Usually that needs no care, because a phi's
;;; destination is defined nowhere else and so is nobody's argument — but a
;;; block that is its own predecessor can have two phis that swap, and then the
;;; copies go through temporaries, which is Sreedhar's answer and which
;;; coalescing is expected to remove again.

(define-module (wolv outofssa)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (any))
  #:use-module (wolv ir)
  #:use-module (wolv regset)
  #:export (destruct! destruct-module!))

;; Replace every phi in `f` with copies in its predecessors.
(define (destruct! f)
  (for-each
   (lambda (b)
     (unless (null? (block-phis b))
       (for-each
        (lambda (pred)
          (let ((source (block-of f pred)))
            (unless (= (length (succs source)) 1)
              (error (string-append pred " -> " (block-label b) " is a critical edge")))
            (copy-in-parallel! f source
                               (map (lambda (p)
                                      (cons (phi-dst p) (cdr (phi-arg p pred))))
                                    (block-phis b)))))
        (block-preds b))
       (set-block-phis! b '())))
   (walk f))
  (recompute-preds! f))

(define (destruct-module! m) (for-each destruct! (module-funcs m)))

(define (copy-in-parallel! f b moves)
  (let ((real (filter (lambda (m) (not (eqv? (car m) (cdr m)))) moves)))
    (unless (null? real)
      (let* ((written (regset-of-list (map car real)))
             (copies
              (cond
               ;; Something read is also written, so the two halves cannot be
               ;; one list.
               ((any (lambda (r) (regset-member? written r)) (map cdr real))
                (let ((through (map-in-order (lambda (m) (cons (car m) (new-reg! f)))
                                            real)))
                  (append (map (lambda (m)
                                 (i-move (cdr (assv (car m) through)) (cdr m)))
                               real)
                          (map (lambda (m)
                                 (i-move (car m) (cdr (assv (car m) through))))
                               real))))
               (else (map (lambda (m) (i-move (car m) (cdr m))) real))))
             (at (- (count b) 1)))
        (set-instrs! b (append (list-head (instrs b) at)
                               copies
                               (list-tail (instrs b) at)))))))

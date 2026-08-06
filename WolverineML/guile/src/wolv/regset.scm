;;; Sets of registers, as sorted lists.
;;;
;;; Registers are small integers and the sets of them are small, so a sorted
;;; list is the cheap representation — and it is the one that answers the
;;; question the rest of the compiler keeps asking, which is not "is this in the
;;; set" but "walk the set in a fixed order".  A hash table would answer the
;;; first faster and the second not at all, and two runs that walked it in two
;;; orders would colour the same program two ways.
;;;
;;; `equal?` on two of these is set equality, which is what the liveness
;;; iteration tests for.

(define-module (wolv regset)
  #:export (regset-empty regset-of regset-of-list regset-add regset-remove regset-member?
            regset-union regset-subtract regset->list regset-count regset-null?))

(define regset-empty '())

(define (regset-of . rs) (regset-of-list rs))

(define (regset-of-list rs)
  (let loop ((xs (sort rs <)) (acc '()))
    (cond
     ((null? xs) (reverse acc))
     ((and (pair? acc) (= (car acc) (car xs))) (loop (cdr xs) acc))
     (else (loop (cdr xs) (cons (car xs) acc))))))

(define (regset-add s r)
  (let loop ((xs s) (acc '()))
    (cond
     ((null? xs) (reverse (cons r acc)))
     ((= (car xs) r) s)
     ((> (car xs) r) (append (reverse acc) (cons r xs)))
     (else (loop (cdr xs) (cons (car xs) acc))))))

(define (regset-remove s r)
  (if (memv r s) (filter (lambda (x) (not (= x r))) s) s))

(define (regset-member? s r) (and (memv r s) #t))

(define (regset-union a b)
  (let loop ((a a) (b b) (acc '()))
    (cond
     ((null? a) (append (reverse acc) b))
     ((null? b) (append (reverse acc) a))
     ((< (car a) (car b)) (loop (cdr a) b (cons (car a) acc)))
     ((> (car a) (car b)) (loop a (cdr b) (cons (car b) acc)))
     (else (loop (cdr a) (cdr b) (cons (car a) acc))))))

(define (regset-subtract a b)
  (let loop ((a a) (b b) (acc '()))
    (cond
     ((null? a) (reverse acc))
     ((null? b) (append (reverse acc) a))
     ((< (car a) (car b)) (loop (cdr a) b (cons (car a) acc)))
     ((> (car a) (car b)) (loop a (cdr b) acc))
     (else (loop (cdr a) (cdr b) acc)))))

;; Already sorted, which is the whole point.
(define (regset->list s) s)
(define (regset-count s) (length s))
(define (regset-null? s) (null? s))

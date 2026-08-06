;;; Optimisation on SSA.
;;;
;;; Five small passes run to a fixed point.  Each is cheap because SSA makes it
;;; cheap: a register has one definition, so constant folding and copy
;;; propagation are a lookup rather than a dataflow problem, and a phi whose
;;; arguments all agree is a copy that was never needed.
;;;
;;;     fold constants   ->  arithmetic on known values
;;;     propagate copies ->  `<i-move>`, and phis that turned into one
;;;     simplify phis    ->  a phi with one distinct argument is that argument
;;;     fold branches    ->  a branch on a known value, and the blocks it strands
;;;     dead code        ->  anything computed and not used

(define-module (wolv opt)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (any delete-duplicates))
  #:use-module (ice-9 format)
  #:use-module (wolv i64)
  #:use-module (wolv ir)
  #:export (optimise! optimise-func!))

(define (optimise! m) (for-each optimise-func! (module-funcs m)))

(define (optimise-func! f)
  ;; Every pass runs every round: they are cheap, and one enables another.
  (let ((passes (list fold-constants! propagate-copies! simplify-phis!
                      fold-branches! dead-code!)))
    (let round ()
      (let ((changes (map-in-order (lambda (run) (run f)) passes)))
        (when (any (lambda (x) x) changes) (round))))))

;; -- rewriting ---------------------------------------------------------------

;; Replace registers everywhere they are read, phi arguments included.  A chain
;; of copies is followed to its end, and the `seen` guard is what stops a phi
;; that was simplified into itself from spinning.
(define (rewrite! f mapping)
  (unless (zero? (hash-count (const #t) mapping))
    (define (resolve r)
      (let follow ((r r) (seen '()))
        (if (and (hash-ref mapping r #f) (not (memv r seen)))
            (follow (hash-ref mapping r) (cons r seen))
            r)))
    (for-each
     (lambda (b)
       (map-phis! b (lambda (p)
                      (phi (phi-dst p)
                           (map (lambda (a) (cons (car a) (resolve (cdr a))))
                                (phi-args p)))))
       (map-instrs! b (lambda (i) (map-uses i resolve))))
     (walk f))))

(define (constants f)
  (let ((known (make-hash-table)))
    (for-each (lambda (b)
                (for-each (lambda (i)
                            (when (is-a? i <i-const>)
                              (hash-set! known (instr-dst i) (i-const-value i))))
                          (instrs b)))
              (walk f))
    known))

;; -- the passes --------------------------------------------------------------

(define (fold-constants! f)
  (let ((known (constants f))
        (changed #f))
    (for-each
     (lambda (b)
       (map-instrs!
        b
        (lambda (i)
          (let ((folded (fold-one i known)))
            (cond
             (folded
              (when (is-a? folded <i-const>)
                (hash-set! known (instr-dst folded) (i-const-value folded)))
              (set! changed #t)
              folded)
             (else i))))))
     (walk f))
    changed))

(define-generic fold-one)

(define-method (fold-one (i <instr>) known) #f)

(define-method (fold-one (i <i-bin>) known)
  (let* ((dst (instr-dst i))
         (op (arith-op i))
         (lhs (arith-lhs i))
         (rhs (arith-rhs i))
         (a (hash-ref known lhs #f))
         (b (hash-ref known rhs #f)))
    (cond
     ((and a b) (let ((value (arith op a b))) (and value (i-const dst value))))
     ;; The identities are worth having on their own: `x shl 0` and `x * 1` come
     ;; out of lowering an index, and folding them is what lets the selector see
     ;; one `add` where there were three instructions.
     ((and (eqv? b 0) (member op '("+" "-" "or" "xor" "shl" "shr"))) (i-move dst lhs))
     ((and (eqv? b 1) (member op '("*" "/"))) (i-move dst lhs))
     ((and (eqv? a 0) (string=? op "+")) (i-move dst rhs))
     (else #f))))

(define-method (fold-one (i <i-cmp>) known)
  (let ((a (hash-ref known (arith-lhs i) #f))
        (b (hash-ref known (arith-rhs i) #f)))
    (and a b (i-const (instr-dst i) (if (order (arith-op i) a b) 1 0)))))

;; The arithmetic of the machine, done here rather than in the host's width.
(define (arith op a b)
  (cond
   ((string=? op "+") (i64+ a b))
   ((string=? op "-") (i64- a b))
   ((string=? op "*") (i64* a b))
   ((string=? op "/") (and (not (zero? b)) (i64-quotient a b)))
   ((string=? op "mod") (and (not (zero? b)) (i64-remainder a b)))
   ((string=? op "and") (i64-and a b))
   ((string=? op "or") (i64-or a b))
   ((string=? op "xor") (i64-xor a b))
   ((string=? op "shl") (i64-shl a b))
   ((string=? op "shr") (i64-shr a b))
   (else #f)))

(define (order op a b)
  (cond
   ((string=? op "=") (= a b))
   ((string=? op "<>") (not (= a b)))
   ((string=? op "<") (< a b))
   ((string=? op "<=") (<= a b))
   ((string=? op ">") (> a b))
   ((string=? op ">=") (>= a b))
   ((string=? op "u<") (< (unsigned a) (unsigned b)))
   ((string=? op "u>=") (>= (unsigned a) (unsigned b)))
   (else (error "unknown comparison" op))))

(define (propagate-copies! f)
  (let ((mapping (make-hash-table)))
    (for-each (lambda (b)
                (for-each (lambda (i)
                            (when (is-a? i <i-move>)
                              (hash-set! mapping (instr-dst i) (i-move-src i))))
                          (instrs b)))
              (walk f))
    (cond
     ((zero? (hash-count (const #t) mapping)) #f)
     (else
      (rewrite! f mapping)
      (for-each (lambda (b)
                  (set-instrs! b (filter (lambda (i) (not (is-a? i <i-move>)))
                                         (instrs b))))
                (walk f))
      #t))))

(define (simplify-phis! f)
  (let ((mapping (make-hash-table))
        (changed #f))
    (for-each
     (lambda (b)
       (set-block-phis!
        b
        (filter
         (lambda (p)
           (let ((others (delete-duplicates
                          (filter (lambda (r) (not (eqv? r (phi-dst p))))
                                  (map cdr (phi-args p))))))
             (cond
              ((= (length others) 1)
               (hash-set! mapping (phi-dst p) (car others))
               (set! changed #t)
               #f)
              (else #t))))
         (block-phis b))))
     (walk f))
    (when changed (rewrite! f mapping))
    changed))

(define (fold-branches! f)
  (let ((known (constants f))
        (changed #f))
    (for-each
     (lambda (b)
       (let ((t (terminator b)))
         (when (is-a? t <i-cbr>)
           (let ((value (hash-ref known (i-cbr-test t) #f)))
             (when (or value (equal? (i-cbr-then t) (i-cbr-else t)))
               (let ((taken (if (or (not value) (not (zero? value)))
                                (i-cbr-then t)
                                (i-cbr-else t))))
                 (set-instrs! b (append (list-head (instrs b) (- (count b) 1))
                                        (list (i-jmp taken))))
                 (set! changed #t)))))))
     (walk f))
    (when changed (drop-unreachable! f))
    changed))

;; Removing one dead value can make another dead, so this one has a fixed point
;; of its own rather than waiting for the next round.
(define (dead-code! f)
  (let round ((changed #f))
    (let ((used (make-hash-table))
          (again #f))
      (for-each
       (lambda (b)
         (for-each (lambda (p)
                     (for-each (lambda (a) (hash-set! used (cdr a) #t)) (phi-args p)))
                   (block-phis b))
         (for-each (lambda (i)
                     (for-each (lambda (r) (hash-set! used r #t)) (uses i)))
                   (instrs b)))
       (walk f))
      (for-each
       (lambda (b)
         (let ((phis (filter (lambda (p) (hash-ref used (phi-dst p) #f)) (block-phis b))))
           (unless (= (length phis) (length (block-phis b)))
             (set-block-phis! b phis)
             (set! again #t)))
         (let ((kept (filter (lambda (i)
                               (let ((d (defs i)))
                                 (not (and d (not (hash-ref used d #f))
                                           (not (has-effect? i))))))
                             (instrs b))))
           (unless (= (length kept) (length (instrs b)))
             (set-instrs! b kept)
             (set! again #t))))
       (walk f))
      (if again (round #t) changed))))

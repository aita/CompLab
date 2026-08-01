#lang racket/base

;; Optimisation on SSA.
;;
;; Five small passes run to a fixed point.  Each is cheap because SSA makes it
;; cheap: a register has one definition, so constant folding and copy propagation
;; are a lookup rather than a dataflow problem, and a phi whose arguments all
;; agree is a copy that was never needed.
;;
;;     fold constants   ->  arithmetic on known values
;;     propagate copies ->  `i:move`, and phis that turned into one
;;     simplify phis    ->  a phi with one distinct argument is that argument
;;     fold branches    ->  a branch on a known value, and the blocks it strands
;;     dead code        ->  anything computed and not used

(require racket/list
         racket/match
         racket/set
         "i64.rkt"
         (prefix-in ir: "ir.rkt"))

(provide optimise! optimise-func!)

(define (optimise! m)
  (for ([f (in-list (ir:module*-funcs m))]) (optimise-func! f)))

(define (optimise-func! f)
  ;; Every pass runs every round: they are cheap, and one enables another.
  (define passes (list fold-constants! propagate-copies! simplify-phis!
                       fold-branches! dead-code!))
  (let round ()
    (define changes (for/list ([run (in-list passes)]) (run f)))
    (when (ormap values changes) (round))))

;; -- rewriting ---------------------------------------------------------------

;; Replace registers everywhere they are read, phi arguments included.  A chain
;; of copies is followed to its end, and the `seen` guard is what stops a phi
;; that was simplified into itself from spinning.
(define (rewrite! f mapping)
  (unless (zero? (hash-count mapping))
    (define (resolve r)
      (let follow ([r r] [seen (seteqv)])
        (if (and (hash-ref mapping r #f) (not (set-member? seen r)))
            (follow (hash-ref mapping r) (set-add seen r))
            r)))
    (for ([b (in-list (ir:walk f))])
      (ir:map-phis! b (λ (p) (ir:phi (ir:phi-dst p)
                                     (for/list ([a (in-list (ir:phi-args p))])
                                       (cons (car a) (resolve (cdr a)))))))
      (ir:map-instrs! b (λ (i) (ir:map-uses i resolve))))))

(define (constants f)
  (define known (make-hash))
  (for* ([b (in-list (ir:walk f))] [i (in-list (ir:instrs b))])
    (match i
      [(ir:i:const dst value) (hash-set! known dst value)]
      [_ (void)]))
  known)

;; -- the passes --------------------------------------------------------------

(define (fold-constants! f)
  (define known (constants f))
  (define changed #f)
  (for ([b (in-list (ir:walk f))])
    (ir:map-instrs!
     b
     (λ (i)
       (define folded (fold-one i known))
       (cond
         [folded
          (when (ir:i:const? folded)
            (hash-set! known (ir:i:const-dst folded) (ir:i:const-value folded)))
          (set! changed #t)
          folded]
         [else i]))))
  changed)

(define (fold-one i known)
  (define (known-value r) (hash-ref known r #f))
  (match i
    [(ir:i:bin dst op lhs rhs)
     (define a (known-value lhs))
     (define b (known-value rhs))
     (cond
       [(and a b) (let ([value (arith op a b)]) (and value (ir:i:const dst value)))]
       ;; The identities are worth having on their own: `x shl 0` and `x * 1`
       ;; come out of lowering an index, and folding them is what lets the
       ;; selector see one `add` where there were three instructions.
       [(and (eqv? b 0) (member op '("+" "-" "or" "xor" "shl" "shr"))) (ir:i:move dst lhs)]
       [(and (eqv? b 1) (member op '("*" "/"))) (ir:i:move dst lhs)]
       [(and (eqv? a 0) (string=? op "+")) (ir:i:move dst rhs)]
       [else #f])]
    [(ir:i:cmp dst op lhs rhs)
     (define a (known-value lhs))
     (define b (known-value rhs))
     (and a b (ir:i:const dst (if (order op a b) 1 0)))]
    [_ #f]))

;; The arithmetic of the machine, done here rather than in the host's width.
(define (arith op a b)
  (match op
    ["+" (i64+ a b)]
    ["-" (i64- a b)]
    ["*" (i64* a b)]
    ["/" (and (not (zero? b)) (i64-quotient a b))]
    ["mod" (and (not (zero? b)) (i64-remainder a b))]
    ["and" (i64-and a b)]
    ["or" (i64-or a b)]
    ["xor" (i64-xor a b)]
    ["shl" (i64-shl a b)]
    ["shr" (i64-shr a b)]
    [_ #f]))

(define (order op a b)
  (match op
    ["=" (= a b)]
    ["<>" (not (= a b))]
    ["<" (< a b)]
    ["<=" (<= a b)]
    [">" (> a b)]
    [">=" (>= a b)]
    ["u<" (< (unsigned a) (unsigned b))]
    ["u>=" (>= (unsigned a) (unsigned b))]
    [_ (error 'opt "unknown comparison ~a" op)]))

(define (propagate-copies! f)
  (define mapping (make-hash))
  (for* ([b (in-list (ir:walk f))] [i (in-list (ir:instrs b))])
    (match i
      [(ir:i:move dst src) (hash-set! mapping dst src)]
      [_ (void)]))
  (cond
    [(zero? (hash-count mapping)) #f]
    [else
     (rewrite! f mapping)
     (for ([b (in-list (ir:walk f))])
       (ir:set-instrs! b (filter (λ (i) (not (ir:i:move? i))) (ir:instrs b))))
     #t]))

(define (simplify-phis! f)
  (define mapping (make-hash))
  (define changed #f)
  (for ([b (in-list (ir:walk f))])
    (ir:set-block-phis!
     b
     (for/list ([p (in-list (ir:block-phis b))]
                #:unless
                (let ([others (for/seteqv ([a (in-list (ir:phi-args p))]
                                           #:unless (eqv? (cdr a) (ir:phi-dst p)))
                                (cdr a))])
                  (and (= (set-count others) 1)
                       (begin (hash-set! mapping (ir:phi-dst p) (set-first others))
                              (set! changed #t)
                              #t))))
       p)))
  (when changed (rewrite! f mapping))
  changed)

(define (fold-branches! f)
  (define known (constants f))
  (define changed #f)
  (for ([b (in-list (ir:walk f))])
    (match (ir:terminator b)
      [(ir:i:cbr cnd then els _)
       (define value (hash-ref known cnd #f))
       (when (or value (equal? then els))
         (define taken (if (or (not value) (not (zero? value))) then els))
         (ir:set-instrs! b (append (drop-right (ir:instrs b) 1) (list (ir:i:jmp taken))))
         (set! changed #t))]
      [_ (void)]))
  (when changed (ir:drop-unreachable! f))
  changed)

;; Removing one dead value can make another dead, so this one has a fixed point
;; of its own rather than waiting for the next round.
(define (dead-code! f)
  (let round ([changed #f])
    (define used (make-hash))
    (for ([b (in-list (ir:walk f))])
      (for* ([p (in-list (ir:block-phis b))] [a (in-list (ir:phi-args p))])
        (hash-set! used (cdr a) #t))
      (for* ([i (in-list (ir:instrs b))] [r (in-list (ir:uses i))])
        (hash-set! used r #t)))
    (define again #f)
    (for ([b (in-list (ir:walk f))])
      (define phis (filter (λ (p) (hash-ref used (ir:phi-dst p) #f)) (ir:block-phis b)))
      (unless (= (length phis) (length (ir:block-phis b)))
        (ir:set-block-phis! b phis)
        (set! again #t))
      (define kept
        (for/list ([i (in-list (ir:instrs b))]
                   #:unless (let ([d (ir:defs i)])
                              (and d (not (hash-ref used d #f)) (not (ir:has-effect? i)))))
          i))
      (unless (= (length kept) (length (ir:instrs b)))
        (ir:set-instrs! b kept)
        (set! again #t)))
    (if again (round #t) changed)))

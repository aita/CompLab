#lang racket/base

;; Instruction selection: cover the DAG with ARM instructions.
;;
;; Every node that has to become a register of its own is tiled, largest tile
;; first, pulling its foldable operands into the tile as it goes.  The tiles are
;; the things ARM can do in one instruction that the IR needs several nodes to
;; say:
;;
;;     a + b * c            madd
;;     a - b * c            msub
;;     a + (b << k)         add with a shifted operand
;;     a + 4095             add with an immediate
;;     a * 8                lsl
;;     [a + 24]             a load with the addition as its displacement
;;     a < b, then branch   cmp, and a branch on the flags
;;
;; What comes out is still the same CFG, and still in SSA — a tile defines one
;; new register — so liveness, both allocators and the verifier carry on as
;; before.  What has gone is the guesswork the emitter used to do with its
;; peepholes: an instruction is now chosen where the whole expression is
;; visible, rather than by looking at the line before.

(require racket/list
         racket/set
         (prefix-in dag: "dag.rkt")
         (prefix-in ir: "ir.rkt")
         (prefix-in mach: "mach.rkt")
         (prefix-in live: "liveness.rkt"))

(provide select-module! select! graphs IMMEDIATE)

;; What `add`, `sub` and `cmp` take as an immediate operand.
(define IMMEDIATE 4095)

(define LOGICAL '(("and" . "and") ("or" . "orr") ("xor" . "eor")))
(define SHIFTS '(("shl" . "lsl") ("shr" . "asr")))

(define (select-module! m) (for ([f (in-list (ir:module*-funcs m))]) (select! f)))

(define (select! f)
  (define l (live:analyse f))
  (for ([b (in-list (ir:walk f))])
    (define g (dag:build b (live:live-out l (ir:block-label b))))
    (ir:set-instrs! b (run (selector f g (box '()) (make-hash) (make-hash) (box #f))))))

;; The DAGs a selection would work on, for `wolv emit -s dag`.
(define (graphs f)
  (define l (live:analyse f))
  (for/list ([b (in-list (ir:walk f))])
    (cons (ir:block-label b) (dag:build b (live:live-out l (ir:block-label b))))))

;; `out` is what has been emitted, `done` the nodes that have been, `absorbed`
;; the ones the plan says a tile will swallow, and `fused` the condition code a
;; comparison left for the branch below it.
(struct selector (func graph out done absorbed fused) #:transparent)

(define (emit! s i) (set-box! (selector-out s) (cons i (unbox (selector-out s)))))

(define (machine! s form dst srcs [imm 0] [symbol ""] [effect #f])
  (emit! s (ir:i:machine form dst srcs imm symbol effect)))

(define (nodes s) (dag:dag-nodes (selector-graph s)))
(define (node-at s index) (dag:node-of (selector-graph s) index))
(define (constant s index) (dag:constant (selector-graph s) index))

(define (bin? n op)
  (and (ir:i:bin? (dag:node-instr n)) (string=? (ir:i:bin-op (dag:node-instr n)) op)))

(define (run s)
  (plan! s)
  (for ([n (in-vector (nodes s))] [i (in-naturals)])
    (unless (or (hash-ref (selector-absorbed s) i #f)      ; part of the tile that reads it
                (dag:rematerialisable (selector-graph s) i) ; computed where a register wants it
                (fuse-comparison! s i))
      (hash-set! (selector-done s) i #t)
      (tile! s n)))
  (reverse (unbox (selector-out s))))

;; Decide which nodes a tile is going to swallow, before emitting any.
;;
;; Nothing may be deferred on the chance that its reader takes it.  A node left
;; out of the order and then not absorbed would be computed at its reader
;; instead, and a chain of those — `a + b + c + ...`, where every term has one
;; reader — would move the whole sum to its last line and keep every term alive
;; until then.
(define (plan! s)
  (for ([n (in-vector (nodes s))])
    (when (and (dag:alone? n) (dag:node-reader n)
               (swallows? s (vector-ref (nodes s) (dag:node-reader n)) n))
      (hash-set! (selector-absorbed s) (dag:node-index n) #t))))

;; Whether the instruction chosen for `reader` has room for `node`.
(define (swallows? s reader n)
  (define i (dag:node-instr reader))
  (define operands (dag:node-operands reader))
  (cond
    [(and (ir:i:bin? i) (member (ir:i:bin-op i) '("+" "-")))
     (and (eqv? (second operands) (dag:node-index n))
          (or (as-shift s (dag:node-index n)) (bin? n "*"))
          #t)]
    [(ir:i:load? i)
     (and (eqv? (first operands) (dag:node-index n))
          (displaces s n (ir:i:load-offset i))
          #t)]
    [(ir:i:store? i)
     (and (eqv? (first operands) (dag:node-index n))
          (displaces s n (ir:i:store-offset i))
          #t)]
    [else #f]))

;; `[pointer + 24]`, when what is added to the pointer is a constant.
(define (displaces s n offset)
  (and (bin? n "+")
       (let ([value (constant s (second (dag:node-operands n)))])
         (and value
              (let ([total (+ offset value)])
                (cond
                  [(and (<= 0 total 32760) (zero? (modulo total ir:WORD))) total]
                  [(<= -256 total 255) total]
                  [else #f]))))))

;; -- reading operands --------------------------------------------------------

;; The register holding an operand, computing it here if it was deferred.
;;
;; Only two kinds of node were left out of the order: a constant, which is tiled
;; the first time somebody needs it in a register and read from there afterwards,
;; and a node the plan said would be absorbed, which ends up here only if the
;; tile that was to absorb it changed its mind.
(define (at s index reg)
  (define n (node-at s index))
  (cond
    [(or (not n) (hash-ref (selector-done s) (dag:node-index n) #f)) reg]
    [(or (hash-ref (selector-absorbed s) (dag:node-index n) #f)
         (dag:rematerialisable (selector-graph s) (dag:node-index n)))
     (hash-set! (selector-done s) (dag:node-index n) #t)
     (tile! s n)]
    [else reg]))

;; Compute a deferred operand for a reader that has no tile to take it.
(define (force! s index)
  (define n (node-at s index))
  (when n (at s index (or (dag:node-value n) 0))))

;; -- one node ----------------------------------------------------------------

(define (tile! s n)
  (define i (dag:node-instr n))
  (cond
    [(ir:i:const? i)
     (machine! s "const" (ir:i:const-dst i) '() (ir:i:const-value i))
     (ir:i:const-dst i)]
    [(ir:i:str-const? i)
     (machine! s "adr" (ir:i:str-const-dst i) '() 0 (ir:i:str-const-symbol i))
     (ir:i:str-const-dst i)]
    [(ir:i:bin? i)
     (arithmetic! s n (ir:i:bin-dst i) (ir:i:bin-op i) (ir:i:bin-lhs i) (ir:i:bin-rhs i))
     (ir:i:bin-dst i)]
    [(ir:i:cmp? i)
     (compare! s n (ir:i:cmp-op i) (ir:i:cmp-lhs i) (ir:i:cmp-rhs i))
     (machine! s "cset" (ir:i:cmp-dst i) '() 0 (mach:condition-of (ir:i:cmp-op i)))
     (ir:i:cmp-dst i)]
    [(ir:i:load? i)
     (define-values (pointer offset)
       (address s (first (dag:node-operands n)) (ir:i:load-base i) (ir:i:load-offset i)))
     (machine! s "ldr" (ir:i:load-dst i) (list pointer) offset)
     (ir:i:load-dst i)]
    [(ir:i:store? i)
     (define value (at s (second (dag:node-operands n)) (ir:i:store-src i)))
     (define-values (pointer offset)
       (address s (first (dag:node-operands n)) (ir:i:store-base i) (ir:i:store-offset i)))
     (machine! s "str" #f (list pointer value) offset "" #t)
     (ir:i:store-src i)]
    [else
     ;; Moves, calls, slot accesses and the terminator are machine instructions
     ;; already, and a phi is not in this list at all.  None of them folds
     ;; anything, so every operand that was left to be folded has to be computed
     ;; here instead.
     (for ([index (in-list (dag:node-operands n))]) (force! s index))
     (emit! s (if (and (ir:i:cbr? i) (unbox (selector-fused s)))
                  (struct-copy ir:i:cbr i [code (unbox (selector-fused s))])
                  i))
     (or (ir:defs i) 0)]))

;; -- the tiles ---------------------------------------------------------------

(define (arithmetic! s n dst op lhs rhs)
  (cond
    [(member op '("+" "-")) (additive! s n dst op lhs rhs)]
    [(string=? op "*") (multiply! s n dst lhs rhs)]
    [(string=? op "/") (machine! s "sdiv" dst (both s n lhs rhs))]
    [(member op '("shl" "shr")) (shift! s n dst op lhs rhs)]
    [(member op '("and" "or" "xor")) (logical! s n dst op lhs rhs)]
    [else (error 'select "no instruction for `~a`" op)]))

;; Both operands in registers, which is what the plain forms want.
(define (both s n lhs rhs)
  (define left (at s (first (dag:node-operands n)) lhs))
  (list left (at s (second (dag:node-operands n)) rhs)))

;; `add` and `sub`, in whichever of their four forms fits.
(define (additive! s n dst op lhs rhs)
  (define left (first (dag:node-operands n)))
  (define right (second (dag:node-operands n)))
  ;; A shifted operand comes first: `a + b * 8` is one instruction that way and
  ;; two as a multiply-add, because the 8 would need a register.
  (unless (or (shift-into! s n dst op lhs rhs)
              (multiply-into! s n dst op lhs rhs))
    (define value (constant s right))
    (cond
      [(and value (<= 0 value IMMEDIATE))
       (machine! s (if (string=? op "+") "addi" "subi") dst (list (at s left lhs)) value)]
      [else
       ;; Only addition may take its constant from the other side.
       (define other (and (string=? op "+") (constant s left)))
       (cond
         [(and other (<= 0 other IMMEDIATE))
          (machine! s "addi" dst (list (at s right rhs)) other)]
         [else
          (machine! s (if (string=? op "+") "add" "sub") dst (both s n lhs rhs))])])))

(define (power-of-two? value) (and (> value 0) (zero? (bitwise-and value (sub1 value)))))
(define (log2 value) (sub1 (integer-length value)))

(define (multiply! s n dst lhs rhs)
  (define value (constant s (second (dag:node-operands n))))
  (cond
    [(and value (power-of-two? value))
     (machine! s "lsli" dst (list (at s (first (dag:node-operands n)) lhs)) (log2 value))]
    [else (machine! s "mul" dst (both s n lhs rhs))]))

(define (shift! s n dst op lhs rhs)
  (define value (constant s (second (dag:node-operands n))))
  (cond
    [(and value (<= 0 value) (< value 64))
     (machine! s (string-append (cdr (assoc op SHIFTS)) "i") dst
               (list (at s (first (dag:node-operands n)) lhs)) value)]
    [else (machine! s (cdr (assoc op SHIFTS)) dst (both s n lhs rhs))]))

(define (logical! s n dst op lhs rhs)
  (cond
    ;; Which is how `not` arrives.
    [(and (string=? op "xor") (eqv? (constant s (second (dag:node-operands n))) 1))
     (machine! s "eori" dst (list (at s (first (dag:node-operands n)) lhs)) 1)]
    [else (machine! s (cdr (assoc op LOGICAL)) dst (both s n lhs rhs))]))

;; `a + b * c` and `a - b * c` are one instruction each.
(define (multiply-into! s n dst op lhs rhs)
  (define product (node-at s (second (dag:node-operands n))))
  (and product (dag:alone? product) (bin? product "*")
       (let* ([i (dag:node-instr product)]
              [factors (list (at s (first (dag:node-operands product)) (ir:i:bin-lhs i))
                             (at s (second (dag:node-operands product)) (ir:i:bin-rhs i)))])
         (machine! s (if (string=? op "+") "madd" "msub") dst
                   (append factors (list (at s (first (dag:node-operands n)) lhs))))
         #t)))

;; The second operand of an `add` may be shifted on the way in.
(define (shift-into! s n dst op lhs rhs)
  (define shift (as-shift s (second (dag:node-operands n))))
  (and shift
       (let* ([shifted (car shift)]
              [amount (cdr shift)]
              [i (dag:node-instr shifted)])
         (machine! s (if (string=? op "+") "adds" "subs") dst
                   (list (at s (first (dag:node-operands n)) lhs)
                         (at s (first (dag:node-operands shifted)) (ir:i:bin-lhs i)))
                   amount)
         #t)))

;; A `x << k` that can be folded, however it was written: `* 8` says it too.
;;
;; This decides nothing and emits nothing, so the plan and the tiles can both ask
;; it and get the same answer.
(define (as-shift s index)
  (define n (node-at s index))
  (and n (dag:alone? n)
       (let* ([i (dag:node-instr n)]
              [amount (constant s (second (dag:node-operands n)))])
         (and amount
              (let ([amount (cond
                              [(string=? (ir:i:bin-op i) "*")
                               (and (power-of-two? amount) (log2 amount))]
                              [(string=? (ir:i:bin-op i) "shl") amount]
                              [else #f])])
                (and amount (<= 0 amount) (< amount 64) (cons n amount)))))))

;; A pointer and a displacement, taking in an addition if there is one.
(define (address s index base offset)
  (define n (node-at s index))
  (define displaced (and n (dag:alone? n) (displaces s n offset)))
  (if displaced
      (values (at s (first (dag:node-operands n)) (ir:i:bin-lhs (dag:node-instr n))) displaced)
      (values (at s index base) offset)))

;; -- comparisons and the branch that reads them ------------------------------

(define (compare! s n op lhs rhs)
  (define left (first (dag:node-operands n)))
  (define right (second (dag:node-operands n)))
  (define value (constant s right))
  (cond
    [(and value (<= 0 value IMMEDIATE))
     (machine! s "cmpi" #f (list (at s left lhs)) value)]
    [else (machine! s "cmp" #f (list (at s left lhs) (at s right rhs)))]))

;; A comparison the branch below it is the only reader of sets the flags.
(define (fuse-comparison! s index)
  (define all (nodes s))
  (define n (vector-ref all index))
  (define i (dag:node-instr n))
  (define terminator (dag:node-instr (vector-ref all (sub1 (vector-length all)))))
  (and (ir:i:cmp? i)
       (= (add1 index) (sub1 (vector-length all)))
       (ir:i:cbr? terminator)
       (eqv? (ir:i:cbr-cond terminator) (ir:i:cmp-dst i))
       (= (dag:node-users n) 1)
       (not (dag:node-escapes? n))
       (begin
         (compare! s n (ir:i:cmp-op i) (ir:i:cmp-lhs i) (ir:i:cmp-rhs i))
         (set-box! (selector-fused s) (mach:condition-of (ir:i:cmp-op i)))
         #t)))

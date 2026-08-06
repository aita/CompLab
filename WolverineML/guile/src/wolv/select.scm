;;; Instruction selection: cover the DAG with ARM instructions.
;;;
;;; Every node that has to become a register of its own is tiled, largest tile
;;; first, pulling its foldable operands into the tile as it goes.  The tiles
;;; are the things ARM can do in one instruction that the IR needs several nodes
;;; to say:
;;;
;;;     a + b * c            madd
;;;     a - b * c            msub
;;;     a + (b << k)         add with a shifted operand
;;;     a + 4095             add with an immediate
;;;     a * 8                lsl
;;;     [a + 24]             a load with the addition as its displacement
;;;     a < b, then branch   cmp, and a branch on the flags
;;;
;;; What comes out is still the same CFG, and still in SSA — a tile defines one
;;; new register — so liveness, both allocators and the verifier carry on as
;;; before.  What has gone is the guesswork the emitter used to do with its
;;; peepholes: an instruction is now chosen where the whole expression is
;;; visible, rather than by looking at the line before.

(define-module (wolv select)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (first second))
  #:use-module (ice-9 format)
  #:use-module (wolv ir)
  #:use-module (wolv dag)
  #:use-module (wolv mach)
  #:use-module (wolv liveness)
  #:export (select-module! select! graphs IMMEDIATE))

;; What `add`, `sub` and `cmp` take as an immediate operand.
(define IMMEDIATE 4095)

(define LOGICAL '(("and" . "and") ("or" . "orr") ("xor" . "eor")))
(define SHIFTS '(("shl" . "lsl") ("shr" . "asr")))

(define (select-module! m) (for-each select! (module-funcs m)))

(define (select! f)
  (let ((l (analyse f)))
    (for-each
     (lambda (b)
       (let ((g (build b (live-out l (block-label b)))))
         (set-instrs! b (run (make <selector> #:func f #:graph g)))))
     (walk f))))

;; The DAGs a selection would work on, for `wolv emit -s dag`.
(define (graphs f)
  (let ((l (analyse f)))
    (map (lambda (b)
           (cons (block-label b) (build b (live-out l (block-label b)))))
         (walk f))))

;; `out` is what has been emitted, `done` the nodes that have been, `absorbed`
;; the ones the plan says a tile will swallow, and `fused` the condition code a
;; comparison left for the branch below it.
(define-class <selector> ()
  (func #:init-keyword #:func #:getter selector-func)
  (graph #:init-keyword #:graph #:getter selector-graph)
  (out #:init-value '() #:accessor selector-out)
  (done #:init-thunk make-hash-table #:getter selector-done)
  (absorbed #:init-thunk make-hash-table #:getter selector-absorbed)
  (fused #:init-value #f #:accessor selector-fused))

(define (put! s i) (set! (selector-out s) (cons i (selector-out s))))

(define* (machine! s form dst srcs #:optional (imm 0) (symbol "") (effect #f))
  (put! s (i-machine form dst srcs imm symbol effect)))

(define (nodes s) (dag-nodes (selector-graph s)))
(define (node-at s index) (node-of (selector-graph s) index))
(define (const-at s index) (constant (selector-graph s) index))
(define (done? s index) (hash-ref (selector-done s) index #f))
(define (absorbed? s index) (hash-ref (selector-absorbed s) index #f))

(define (bin? n op)
  (and (is-a? (node-instr n) <i-bin>) (string=? (arith-op (node-instr n)) op)))

(define (run s)
  (plan! s)
  (let loop ((i 0))
    (when (< i (vector-length (nodes s)))
      (unless (or (absorbed? s i)                          ; part of a tile above
                  (rematerialisable (selector-graph s) i)  ; made where wanted
                  (fuse-comparison! s i))
        (hash-set! (selector-done s) i #t)
        (tile! (node-instr (vector-ref (nodes s) i)) s (vector-ref (nodes s) i)))
      (loop (+ i 1))))
  (reverse (selector-out s)))

;; Decide which nodes a tile is going to swallow, before emitting any.
;;
;; Nothing may be deferred on the chance that its reader takes it.  A node left
;; out of the order and then not absorbed would be computed at its reader
;; instead, and a chain of those — `a + b + c + ...`, where every term has one
;; reader — would move the whole sum to its last line and keep every term alive
;; until then.
(define (plan! s)
  (for-each
   (lambda (n)
     (when (and (alone? n) (node-reader n)
                (swallows? s (vector-ref (nodes s) (node-reader n)) n))
       (hash-set! (selector-absorbed s) (node-index n) #t)))
   (vector->list (nodes s))))

;; Whether the instruction chosen for `reader` has room for `node`.
(define (swallows? s reader n)
  (let* ((operands (node-operands reader))
         (i (node-instr reader))
         (second-is? (lambda (index) (eqv? (second operands) index)))
         (first-is? (lambda (index) (eqv? (first operands) index))))
    (cond
     ((and (is-a? i <i-bin>) (member (arith-op i) '("+" "-")))
      (and (second-is? (node-index n))
           (or (as-shift s (node-index n)) (bin? n "*"))
           #t))
     ((is-a? i <i-load>)
      (and (first-is? (node-index n)) (displaces s n (i-load-offset i)) #t))
     ((is-a? i <i-store>)
      (and (first-is? (node-index n)) (displaces s n (i-store-offset i)) #t))
     (else #f))))

;; `[pointer + 24]`, when what is added to the pointer is a constant.
(define (displaces s n offset)
  (and (bin? n "+")
       (let ((value (const-at s (second (node-operands n)))))
         (and value
              (let ((total (+ offset value)))
                (cond
                 ((and (<= 0 total) (<= total 32760) (zero? (modulo total WORD))) total)
                 ((and (<= -256 total) (<= total 255)) total)
                 (else #f)))))))

;; -- reading operands --------------------------------------------------------

;; The register holding an operand, computing it here if it was deferred.
;;
;; Only two kinds of node were left out of the order: a constant, which is tiled
;; the first time somebody needs it in a register and read from there
;; afterwards, and a node the plan said would be absorbed, which ends up here
;; only if the tile that was to absorb it changed its mind.
(define (at s index reg)
  (let ((n (node-at s index)))
    (cond
     ((or (not n) (done? s (node-index n))) reg)
     ((or (absorbed? s (node-index n))
          (rematerialisable (selector-graph s) (node-index n)))
      (hash-set! (selector-done s) (node-index n) #t)
      (tile! (node-instr n) s n))
     (else reg))))

;; Compute a deferred operand for a reader that has no tile to take it.
(define (force! s index)
  (let ((n (node-at s index)))
    (when n (at s index (or (node-value n) 0)))))

;; -- one node ----------------------------------------------------------------

(define-generic tile!)

(define-method (tile! (i <i-const>) s n)
  (machine! s "const" (instr-dst i) '() (i-const-value i))
  (instr-dst i))

(define-method (tile! (i <i-str-const>) s n)
  (machine! s "adr" (instr-dst i) '() 0 (i-str-const-symbol i))
  (instr-dst i))

(define-method (tile! (i <i-bin>) s n)
  (arithmetic! s n (instr-dst i) (arith-op i) (arith-lhs i) (arith-rhs i))
  (instr-dst i))

(define-method (tile! (i <i-cmp>) s n)
  (compare! s n (arith-op i) (arith-lhs i) (arith-rhs i))
  (machine! s "cset" (instr-dst i) '() 0 (condition-of (arith-op i)))
  (instr-dst i))

(define-method (tile! (i <i-load>) s n)
  (call-with-values
      (lambda () (address s (first (node-operands n)) (i-load-base i) (i-load-offset i)))
    (lambda (pointer displaced)
      (machine! s "ldr" (instr-dst i) (list pointer) displaced)
      (instr-dst i))))

(define-method (tile! (i <i-store>) s n)
  (let ((value (at s (second (node-operands n)) (i-store-src i))))
    (call-with-values
        (lambda () (address s (first (node-operands n)) (i-store-base i)
                            (i-store-offset i)))
      (lambda (pointer displaced)
        (machine! s "str" #f (list pointer value) displaced "" #t)
        (i-store-src i)))))

;; Moves, calls, slot accesses and the terminator are machine instructions
;; already, and a phi is not in this list at all.  None of them folds anything,
;; so every operand that was left to be folded has to be computed here instead.
(define-method (tile! (i <instr>) s n)
  (for-each (lambda (index) (force! s index)) (node-operands n))
  (put! s (if (and (is-a? i <i-cbr>) (selector-fused s))
              (i-cbr (i-cbr-test i) (i-cbr-then i) (i-cbr-else i) (selector-fused s))
              i))
  (or (defs i) 0))

;; -- the tiles ---------------------------------------------------------------

(define (arithmetic! s n dst op lhs rhs)
  (cond
   ((member op '("+" "-")) (additive! s n dst op lhs rhs))
   ((string=? op "*") (multiply! s n dst lhs rhs))
   ((string=? op "/") (machine! s "sdiv" dst (both s n lhs rhs)))
   ((member op '("shl" "shr")) (shift! s n dst op lhs rhs))
   ((member op '("and" "or" "xor")) (logical! s n dst op lhs rhs))
   (else (error (format #f "no instruction for `~a`" op)))))

;; Both operands in registers, which is what the plain forms want.
(define (both s n lhs rhs)
  (let* ((left (at s (first (node-operands n)) lhs))
         (right (at s (second (node-operands n)) rhs)))
    (list left right)))

;; `add` and `sub`, in whichever of their four forms fits.
(define (additive! s n dst op lhs rhs)
  (let ((left (first (node-operands n)))
        (right (second (node-operands n))))
    ;; A shifted operand comes first: `a + b * 8` is one instruction that way
    ;; and two as a multiply-add, because the 8 would need a register.
    (unless (or (shift-into! s n dst op lhs rhs)
                (multiply-into! s n dst op lhs rhs))
      (let ((value (const-at s right)))
        (cond
         ((and value (<= 0 value) (<= value IMMEDIATE))
          (machine! s (if (string=? op "+") "addi" "subi") dst (list (at s left lhs)) value))
         (else
          ;; Only addition may take its constant from the other side.
          (let ((other (and (string=? op "+") (const-at s left))))
            (cond
             ((and other (<= 0 other) (<= other IMMEDIATE))
              (machine! s "addi" dst (list (at s right rhs)) other))
             (else
              (machine! s (if (string=? op "+") "add" "sub") dst (both s n lhs rhs)))))))))))

(define (power-of-two? value) (and (> value 0) (zero? (logand value (- value 1)))))
(define (log2 value) (- (integer-length value) 1))

(define (multiply! s n dst lhs rhs)
  (let ((value (const-at s (second (node-operands n)))))
    (cond
     ((and value (power-of-two? value))
      (machine! s "lsli" dst (list (at s (first (node-operands n)) lhs)) (log2 value)))
     (else (machine! s "mul" dst (both s n lhs rhs))))))

(define (shift! s n dst op lhs rhs)
  (let ((value (const-at s (second (node-operands n)))))
    (cond
     ((and value (<= 0 value) (< value 64))
      (machine! s (string-append (cdr (assoc op SHIFTS)) "i") dst
                (list (at s (first (node-operands n)) lhs)) value))
     (else (machine! s (cdr (assoc op SHIFTS)) dst (both s n lhs rhs))))))

(define (logical! s n dst op lhs rhs)
  (cond
   ;; Which is how `not` arrives.
   ((and (string=? op "xor") (eqv? (const-at s (second (node-operands n))) 1))
    (machine! s "eori" dst (list (at s (first (node-operands n)) lhs)) 1))
   (else (machine! s (cdr (assoc op LOGICAL)) dst (both s n lhs rhs)))))

;; `a + b * c` and `a - b * c` are one instruction each.
(define (multiply-into! s n dst op lhs rhs)
  (let ((product (node-at s (second (node-operands n)))))
    (and product (alone? product) (bin? product "*")
         (let* ((i (node-instr product))
                (factors (let* ((a (at s (first (node-operands product)) (arith-lhs i)))
                                (b (at s (second (node-operands product)) (arith-rhs i))))
                           (list a b))))
           (machine! s (if (string=? op "+") "madd" "msub") dst
                     (append factors (list (at s (first (node-operands n)) lhs))))
           #t))))

;; The second operand of an `add` may be shifted on the way in.
(define (shift-into! s n dst op lhs rhs)
  (let ((shift (as-shift s (second (node-operands n)))))
    (and shift
         (let* ((shifted (car shift))
                (amount (cdr shift))
                (i (node-instr shifted))
                (base (at s (first (node-operands n)) lhs))
                (other (at s (first (node-operands shifted)) (arith-lhs i))))
           (machine! s (if (string=? op "+") "adds" "subs") dst (list base other) amount)
           #t))))

;; A `x << k` that can be folded, however it was written: `* 8` says it too.
;;
;; This decides nothing and emits nothing, so the plan and the tiles can both
;; ask it and get the same answer.
(define (as-shift s index)
  (let ((n (node-at s index)))
    (and n (alone? n)
         (let* ((i (node-instr n))
                (amount (const-at s (second (node-operands n)))))
           (and amount
                (let ((amount (cond
                               ((string=? (arith-op i) "*")
                                (and (power-of-two? amount) (log2 amount)))
                               ((string=? (arith-op i) "shl") amount)
                               (else #f))))
                  (and amount (<= 0 amount) (< amount 64) (cons n amount))))))))

;; A pointer and a displacement, taking in an addition if there is one.
(define (address s index base offset)
  (let* ((n (node-at s index))
         (displaced (and n (alone? n) (displaces s n offset))))
    (if displaced
        (values (at s (first (node-operands n)) (arith-lhs (node-instr n))) displaced)
        (values (at s index base) offset))))

;; -- comparisons and the branch that reads them ------------------------------

(define (compare! s n op lhs rhs)
  (let* ((left (first (node-operands n)))
         (right (second (node-operands n)))
         (value (const-at s right)))
    (cond
     ((and value (<= 0 value) (<= value IMMEDIATE))
      (machine! s "cmpi" #f (list (at s left lhs)) value))
     (else (machine! s "cmp" #f (both s n lhs rhs))))))

;; A comparison the branch below it is the only reader of sets the flags.
(define (fuse-comparison! s index)
  (let* ((all (nodes s))
         (n (vector-ref all index))
         (i (node-instr n))
         (final (node-instr (vector-ref all (- (vector-length all) 1)))))
    (and (is-a? i <i-cmp>)
         (is-a? final <i-cbr>)
         (= (+ index 1) (- (vector-length all) 1))
         (eqv? (i-cbr-test final) (instr-dst i))
         (= (node-users n) 1)
         (not (node-escapes? n))
         (begin
           (compare! s n (arith-op i) (arith-lhs i) (arith-rhs i))
           (set! (selector-fused s) (condition-of (arith-op i)))
           #t))))

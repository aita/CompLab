#lang racket/base

;; The data-flow DAG of one basic block.
;;
;; Instruction selection wants to see a block as expressions, not as a list:
;; `a + (i << 3)` is one ARM instruction and `a + b*c` is another, and neither is
;; visible while the operands are separate lines with names in between.  So each
;; block is read into a graph — a node per instruction, an edge per operand — and
;; the selector covers that graph with instructions.
;;
;; It is a graph and not a tree because a value can be read twice.  That is what
;; `users` counts, and it is what decides whether a node may be folded into the
;; instruction that reads it or has to become an instruction of its own: a node
;; read twice would otherwise be computed twice.  A value that leaves the block
;; counts as read as well, and so does one a phi in a successor names.
;;
;; Only pure nodes are ever folded, and only into a reader whose instruction
;; really absorbs them.  Both halves matter.  Folding moves a computation to
;; where it is read, which is fine for arithmetic and not fine for a load,
;; because a store in between would change what it reads; and folding a chain of
;; nodes that nothing absorbs would move a whole expression to its last line,
;; leaving every value it read alive until then.  So the selector plans first —
;; it asks, of each node with one reader, whether that reader has a tile that
;; takes it — and everything else is computed where it was written.

(require racket/list
         racket/set
         racket/string
         racket/format
         (prefix-in ir: "ir.rkt"))

(provide (struct-out node) (struct-out dag)
         node-value alone? build node-of rematerialisable constant show)

;; `operands` holds a node index for a value this block computed, and #f for one
;; that came from outside it.  `reader` is the only node that reads it, when
;; there is one.
(struct node (index instr operands [users #:mutable] [reader #:mutable]
                    [escapes? #:mutable])
  #:transparent)

(struct dag (nodes by-value) #:transparent)

(define (node-value n) (ir:defs (node-instr n)))

;; Read exactly once, inside the block, and computable where read.
(define (alone? n)
  (and (= (node-users n) 1) (not (node-escapes? n)) (ir:i:bin? (node-instr n))))

;; `live-out` includes what the phis of the successors will read.
(define (build block live-out)
  (define by-value (make-hash))
  (define nodes
    (for/list ([instr (in-list (ir:instrs block))] [i (in-naturals)])
      (define operands (for/list ([r (in-list (ir:uses instr))]) (hash-ref by-value r #f)))
      (define n (node i instr operands 0 #f #f))
      (define defined (ir:defs instr))
      (when defined (hash-set! by-value defined i))
      n))
  (define indexed (list->vector nodes))
  (for* ([n (in-list nodes)] [operand (in-list (node-operands n))] #:when operand)
    (define read (vector-ref indexed operand))
    (set-node-users! read (add1 (node-users read)))
    (set-node-reader! read (and (= (node-users read) 1) (node-index n))))
  (for ([n (in-list nodes)])
    (define value (node-value n))
    (when (and value (set-member? live-out value)) (set-node-escapes?! n #t)))
  (dag indexed by-value))

(define (node-of g index) (and index (vector-ref (dag-nodes g) index)))

;; A constant, which costs nothing to repeat and is often not an instruction at
;; all once it has become an immediate operand.
(define (rematerialisable g index)
  (define n (node-of g index))
  (and n (not (node-escapes? n)) (ir:i:const? (node-instr n)) n))

;; The value at `index`, if it is a constant — however many read it.  Even one
;; that has to exist in a register for somebody else can be an immediate here,
;; so this asks less than `rematerialisable` does.
(define (constant g index)
  (define n (node-of g index))
  (and n (ir:i:const? (node-instr n)) (ir:i:const-value (node-instr n))))

(define (plain r) (format "%~a" r))

(define (show g)
  (string-join
   (for/list ([n (in-vector (dag-nodes g))])
     (define reads
       (string-join (for/list ([o (in-list (node-operands n))])
                      (if o (number->string o) "-"))
                    ", "))
     (define marks
       (string-append (if (node-escapes? n) "*" "")
                      (if (ir:has-effect? (node-instr n)) "!" "")))
     (format "  ~a~a ~a reads [~a]  users ~a"
             (~a (node-index n) #:min-width 3 #:align 'right)
             (~a marks #:min-width 2)
             (~a (ir:show-instr plain (node-instr n)) #:min-width 38)
             reads (node-users n)))
   "\n"))

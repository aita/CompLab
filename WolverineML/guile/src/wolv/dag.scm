;;; The data-flow DAG of one basic block.
;;;
;;; Instruction selection wants to see a block as expressions, not as a list:
;;; `a + (i << 3)` is one ARM instruction and `a + b*c` is another, and neither
;;; is visible while the operands are separate lines with names in between.  So
;;; each block is read into a graph — a node per instruction, an edge per
;;; operand — and the selector covers that graph with instructions.
;;;
;;; It is a graph and not a tree because a value can be read twice.  That is
;;; what `users` counts, and it is what decides whether a node may be folded
;;; into the instruction that reads it or has to become an instruction of its
;;; own: a node read twice would otherwise be computed twice.  A value that
;;; leaves the block counts as read as well, and so does one a phi in a
;;; successor names.
;;;
;;; Only pure nodes are ever folded, and only into a reader whose instruction
;;; really absorbs them.  Both halves matter.  Folding moves a computation to
;;; where it is read, which is fine for arithmetic and not fine for a load,
;;; because a store in between would change what it reads; and folding a chain
;;; of nodes that nothing absorbs would move a whole expression to its last
;;; line, leaving every value it read alive until then.  So the selector plans
;;; first — it asks, of each node with one reader, whether that reader has a
;;; tile that takes it — and everything else is computed where it was written.

(define-module (wolv dag)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (wolv ir)
  #:use-module (wolv regset)
  #:export (<node> node-index node-instr node-operands node-users node-reader
            node-escapes? node-value alone?
            <dag> dag-nodes dag-by-value
            build node-of node-count rematerialisable constant show))

;; `operands` holds a node index for a value this block computed, and #f for one
;; that came from outside it.  `reader` is the only node that reads it, when
;; there is one.
(define-class <node> ()
  (index #:init-keyword #:index #:getter node-index)
  (instr #:init-keyword #:instr #:getter node-instr)
  (operands #:init-keyword #:operands #:getter node-operands)
  (users #:init-value 0 #:accessor node-users)
  (reader #:init-value #f #:accessor node-reader)
  (escapes? #:init-value #f #:accessor node-escapes?))

(define-class <dag> ()
  (nodes #:init-keyword #:nodes #:getter dag-nodes)
  (by-value #:init-keyword #:by-value #:getter dag-by-value))

(define (node-value n) (defs (node-instr n)))

;; Read exactly once, inside the block, and computable where read.
(define (alone? n)
  (and (= (node-users n) 1)
       (not (node-escapes? n))
       (is-a? (node-instr n) <i-bin>)))

;; `live-out` includes what the phis of the successors will read.
(define (build block live-out)
  (let ((by-value (make-hash-table))
        (nodes '()))
    (let loop ((is (instrs block)) (i 0))
      (unless (null? is)
        (let* ((instr (car is))
               (operands (map (lambda (r) (hash-ref by-value r #f)) (uses instr)))
               (n (make <node> #:index i #:instr instr #:operands operands))
               (defined (defs instr)))
          (when defined (hash-set! by-value defined i))
          (set! nodes (cons n nodes))
          (loop (cdr is) (+ i 1)))))
    (let ((indexed (list->vector (reverse nodes))))
      (for-each
       (lambda (n)
         (for-each
          (lambda (operand)
            (when operand
              (let ((read (vector-ref indexed operand)))
                (set! (node-users read) (+ 1 (node-users read)))
                (set! (node-reader read)
                      (and (= (node-users read) 1) (node-index n))))))
          (node-operands n)))
       (vector->list indexed))
      (for-each
       (lambda (n)
         (let ((value (node-value n)))
           (when (and value (regset-member? live-out value))
             (set! (node-escapes? n) #t))))
       (vector->list indexed))
      (make <dag> #:nodes indexed #:by-value by-value))))

(define (node-of g index) (and index (vector-ref (dag-nodes g) index)))
(define (node-count g) (vector-length (dag-nodes g)))

;; A constant, which costs nothing to repeat and is often not an instruction at
;; all once it has become an immediate operand.
(define (rematerialisable g index)
  (let ((n (node-of g index)))
    (and n (not (node-escapes? n)) (is-a? (node-instr n) <i-const>) n)))

;; The value at `index`, if it is a constant — however many read it.  Even one
;; that has to exist in a register for somebody else can be an immediate here,
;; so this asks less than `rematerialisable` does.
(define (constant g index)
  (let ((n (node-of g index)))
    (and n (is-a? (node-instr n) <i-const>) (i-const-value (node-instr n)))))

(define (plain r) (format #f "%~a" r))

(define (show g)
  (string-join
   (map (lambda (n)
          (let ((reads (string-join
                        (map (lambda (o) (if o (number->string o) "-"))
                             (node-operands n))
                        ", "))
                (marks (string-append (if (node-escapes? n) "*" "")
                                      (if (has-effect? (node-instr n)) "!" ""))))
            (format #f "  ~3@a~2a ~38a reads [~a]  users ~a"
                    (node-index n) marks
                    (show-instr (node-instr n) plain)
                    reads (node-users n))))
        (vector->list (dag-nodes g)))
   "\n"))

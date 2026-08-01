#lang racket/base

;; SSA construction, the optimiser, and instruction selection.

(require rackunit
         racket/list
         racket/file
         racket/runtime-path
         racket/string
         data/gvector
         "../src/parser.rkt"
         (prefix-in types: "../src/typecheck.rkt")
         (prefix-in dag: "../src/dag.rkt")
         (prefix-in ir: "../src/ir.rkt")
         (prefix-in live: "../src/liveness.rkt")
         (prefix-in low: "../src/lower.rkt")
         (prefix-in opt: "../src/opt.rkt")
         (prefix-in sel: "../src/select.rkt")
         (prefix-in ssa: "../src/ssa.rkt")
         (prefix-in driver: "../src/driver.rkt"))

(provide middle-tests)

(define-runtime-path TOUR "../examples/tour.wol")

(define (build source [checks? #f])
  (define prog (parse source))
  (types:check prog)
  (low:lower prog (low:options checks?)))

(define (in-ssa source [checks? #f])
  (define m (build source checks?))
  (ssa:construct-module! m)
  m)

(define (selected source [checks? #f])
  (define m (in-ssa source checks?))
  (opt:optimise! m)
  (for ([f (in-list (ir:module*-funcs m))]) (ssa:split-critical-edges! f))
  (sel:select-module! m)
  m)

(define (func-named m name)
  (findf (λ (f) (string=? (ir:func-name f) name)) (ir:module*-funcs m)))

(define (instructions f)
  (for*/list ([b (in-list (ir:walk f))] [i (in-list (ir:instrs b))]) i))

;; The instruction forms chosen inside one function, the caller's aside.
(define (forms source [name "f"] [checks? #f])
  (for/list ([i (in-list (instructions (func-named (selected source checks?) name)))]
             #:when (ir:i:machine? i))
    (ir:i:machine-form i)))

(define (count-of xs x) (length (filter (λ (y) (equal? y x)) xs)))

(define LOOP #<<END
fun count (n : int) : int =
  let var i = 0
      var total = 0
  in
    while i < n do (total := total + i; i := i + 1);
    total
  end
val () = printInt (count (10))
END
  )

(define (function body)
  (format "fun f (a : int, b : int, c : int) : int = ~a\nval () = printInt (f (1, 2, 3))"
          body))

(define middle-tests
  (test-suite
   "middle"

   ;; -- SSA --------------------------------------------------------------

   (test-case "lowering writes a variable more than once"
     (define f (second (ir:module*-funcs (build LOOP))))
     (define written (make-hasheqv))
     (for ([i (in-list (instructions f))])
       (when (ir:defs i) (hash-update! written (ir:defs i) add1 0)))
     (check-true (for/or ([(r n) (in-hash written)]) (> n 1)))
     (check-true (for/and ([b (in-list (ir:walk f))]) (null? (ir:block-phis b)))))

   (test-case "construction gives one definition and phis"
     (define f (second (ir:module*-funcs (in-ssa LOOP))))
     (ssa:verify f)
     (check-true (for/or ([b (in-list (ir:walk f))]) (pair? (ir:block-phis b)))
                 "a loop needs phis"))

   (test-case "every function of the tour verifies"
     (for ([f (in-list (ir:module*-funcs
                        (in-ssa (file->string TOUR) #t)))])
       (ssa:verify f)))

   (test-case "the dominators of a diamond"
     (define f (second (ir:module*-funcs
                        (in-ssa (string-append
                                 "fun f (c : bool) : int = if c then 1 else 2\n"
                                 "val () = printInt (f (true))")))))
     (define dom (ssa:dominance-of f))
     (for ([label (in-list (ir:order-list f))])
       (check-true (ssa:dominates? dom (ir:func-entry f) label)))
     (define joins (filter (λ (b) (> (length (ir:block-preds b)) 1)) (ir:walk f)))
     (check-true (pair? joins) "a diamond has a join")
     (for ([join (in-list joins)])
       (check-equal? (hash-ref (ssa:dominance-idom dom) (ir:block-label join))
                     (ir:func-entry f))))

   (test-case "a phi names exactly its predecessors"
     (for* ([f (in-list (ir:module*-funcs (in-ssa LOOP)))]
            [b (in-list (ir:walk f))]
            [p (in-list (ir:block-phis b))])
       (check-equal? (sort (ir:phi-preds p) string<?)
                     (sort (ir:block-preds b) string<?))))

   ;; -- the optimiser ----------------------------------------------------

   (test-case "constants fold"
     (define m (in-ssa "val () = printInt (2 * 3 + 4)"))
     (opt:optimise! m)
     (check-equal? (for/list ([i (in-list (instructions (first (ir:module*-funcs m))))]
                              #:when (ir:i:const? i))
                     (ir:i:const-value i))
                   '(10)))

   (test-case "dead code goes"
     (define m (in-ssa (string-append
                        "fun f (n : int) : int = let val unused = n * n in n + 1 end\n"
                        "val () = printInt (f (2))")))
     (opt:optimise! m)
     (check-false (for/or ([i (in-list (instructions (second (ir:module*-funcs m))))])
                    (and (ir:i:bin? i) (string=? (ir:i:bin-op i) "*")))))

   (test-case "unreachable blocks go"
     (define m (in-ssa "val () = if true then print (\"a\") else print (\"b\")"))
     (opt:optimise! m)
     (check-equal? (for/list ([i (in-list (instructions (first (ir:module*-funcs m))))]
                              #:when (ir:i:call? i))
                     (ir:i:call-callee i))
                   '("wol_print")))

   (test-case "splitting leaves phis only after a jump"
     (define m (in-ssa LOOP #t))
     (opt:optimise! m)
     (for ([f (in-list (ir:module*-funcs m))])
       (ssa:split-critical-edges! f)
       (ssa:verify f)
       (for* ([b (in-list (ir:walk f))] #:when (> (length (ir:succs b)) 1)
              [succ (in-list (ir:succs b))])
         (check-true (null? (ir:block-phis (ir:block-of f succ)))))))

   ;; -- the tiles --------------------------------------------------------

   (test-case "multiply-add is one instruction"
     (define chosen (forms (function "a + b * c")))
     (check-true (and (member "madd" chosen) #t))
     (check-false (member "mul" chosen)))

   (test-case "multiply-subtract is one instruction"
     (define chosen (forms (function "a - b * c")))
     (check-true (and (member "msub" chosen) #t))
     (check-false (member "mul" chosen)))

   (test-case "a shifted operand beats a multiply-add"
     ;; `a + b * 8` is one instruction with a shift and two as a multiply-add.
     (define chosen (forms (function "a + b * 8")))
     (check-equal? (count-of chosen "adds") 1)
     (check-false (member "madd" chosen))
     (check-false (member "lsli" chosen)))

   (test-case "a small constant is an immediate"
     (check-equal? (forms (function "a + 5")) '("addi"))
     (check-equal? (forms (function "(a + 5) - 7")) '("addi" "subi")))

   (test-case "a large constant is not"
     (check-true (and (member "const" (forms (function "a + 100000"))) #t)))

   (test-case "a multiply by a power of two is a shift"
     (define chosen (forms (function "a * 8")))
     (check-true (and (member "lsli" chosen) #t))
     (check-false (member "mul" chosen)))

   (test-case "a comparison read only by its branch sets the flags"
     (define source (string-append "fun f (a : int) : int = if a < 3 then 1 else 2\n"
                                   "val () = printInt (f (1))"))
     (define codes
       (for*/list ([f (in-list (ir:module*-funcs (selected source)))]
                   [b (in-list (ir:walk f))]
                   #:when (ir:i:cbr? (ir:terminator b)))
         (ir:i:cbr-code (ir:terminator b))))
     (check-true (and (member "lt" codes) #t))
     (check-false (member "cset" (forms source))))

   (test-case "a comparison read by something else is a value"
     (check-true (and (member "cset" (forms "fun f (a : int) : bool = a < 3\nval () = print (\"x\")"))
                      #t)))

   (test-case "an array element takes two instructions"
     (define text (driver:compile-to-asm "val a = array (4, 0)\nval () = printInt (a[2] + a[3])"
                                         (driver:options #f #t #f)))
     (check-equal? (for/sum ([l (in-list (string-split text "\n"))]
                             #:when (regexp-match? #rx"^\tldr " l))
                     1)
                   2))

   ;; -- what the plan is for ---------------------------------------------

   (test-case "a constant read twice is still an immediate"
     ;; It costs nothing to repeat, so two readers may both take it.
     (define chosen (forms (function "(a + 1) * (b + 1)")))
     (check-equal? (count-of chosen "addi") 2)
     (check-false (member "const" chosen)))

   (test-case "a chain of additions is not deferred to its last line"
     ;; Folding a whole spine would keep every term live until the end.
     (define m (selected (string-append
                          "fun sum (a : int, b : int, c : int, d : int, e : int, f : int) : int =\n"
                          "  a + b + c + d + e + f\n"
                          "val () = printInt (sum (1, 2, 3, 4, 5, 6))\n")))
     (define f (func-named m "sum"))
     (check-true (<= (live:pressure f (live:analyse f)) 8)))

   (test-case "a node read twice is computed once"
     (check-equal? (count-of (forms (function "let val t = a * b in t + t end")) "mul") 1))

   (test-case "the graph counts its readers"
     (define f (func-named (selected (function "a + b")) "f"))
     (define l (live:analyse f))
     (for ([b (in-list (ir:walk f))])
       (define g (dag:build b (live:live-out l (ir:block-label b))))
       (for ([n (in-vector (dag:dag-nodes g))])
         (check-equal? (dag:node-users n)
                       (for*/sum ([other (in-vector (dag:dag-nodes g))]
                                  [operand (in-list (dag:node-operands other))]
                                  #:when (eqv? operand (dag:node-index n)))
                         1)))))

   (test-case "selection keeps it in SSA"
     (for ([f (in-list (ir:module*-funcs (selected (function "a + b * c + 8") #t)))])
       (ssa:verify f)))))

(module+ test (require rackunit/text-ui) (void (run-tests middle-tests)))

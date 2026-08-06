;;; SSA construction, the optimiser, and instruction selection.

(use-modules (oop goops)
             ((srfi srfi-1) #:select (first second find any every filter-map append-map))
             (srfi srfi-64)
             (ice-9 format)
             (harness)
             (wolv parser)
             (wolv typecheck)
             (wolv ir)
             (wolv liveness)
             (wolv dag)
             (wolv opt)
             (wolv select)
             ((wolv driver) #:select (compile-to-asm options))
             ((wolv lower) #:prefix low:)
             ((wolv ssa) #:prefix ssa:))

(define* (build-ir source #:optional (checks? #f))
  (let ((prog (parse source)))
    (check prog)
    (low:lower prog (low:options checks?))))

(define* (in-ssa source #:optional (checks? #f))
  (let ((m (build-ir source checks?)))
    (ssa:construct-module! m)
    m))

(define* (selected source #:optional (checks? #f))
  (let ((m (in-ssa source checks?)))
    (optimise! m)
    (for-each ssa:split-critical-edges! (module-funcs m))
    (select-module! m)
    m))

(define (func-named m name)
  (find (lambda (f) (string=? (func-name f) name)) (module-funcs m)))

(define (instructions f)
  (append-map instrs (walk f)))

;; The instruction forms chosen inside one function, the caller's aside.
(define* (forms source #:optional (name "f") (checks? #f))
  (map i-machine-form
       (filter (lambda (i) (is-a? i <i-machine>))
               (instructions (func-named (selected source checks?) name)))))

(define (count-of xs x) (length (filter (lambda (y) (equal? y x)) xs)))

(define LOOP
  (lines "fun count (n : int) : int ="
         "  let var i = 0"
         "      var total = 0"
         "  in"
         "    while i < n do (total := total + i; i := i + 1);"
         "    total"
         "  end"
         "val () = printInt (count (10))"))

(define (function body)
  (format #f "fun f (a : int, b : int, c : int) : int = ~a\nval () = printInt (f (1, 2, 3))"
          body))

(with-suite
 "middle"
 (lambda ()

   ;; -- SSA ---------------------------------------------------------------

   (test-assert "lowering writes a variable more than once"
     (let ((f (second (module-funcs (build-ir LOOP))))
           (written (make-hash-table)))
       (for-each (lambda (i)
                   (when (defs i)
                     (hash-set! written (defs i) (+ 1 (hash-ref written (defs i) 0)))))
                 (instructions f))
       (and (hash-fold (lambda (r n acc) (or acc (> n 1))) #f written)
            (every (lambda (b) (null? (block-phis b))) (walk f)))))

   (test-assert "construction gives one definition and phis"
     (let ((f (second (module-funcs (in-ssa LOOP)))))
       (ssa:verify f)
       (any (lambda (b) (pair? (block-phis b))) (walk f))))

   (test-assert "every function of the tour verifies"
     (begin (for-each ssa:verify (module-funcs (in-ssa (read-file "examples/tour.wol") #t)))
            #t))

   (test-assert "the dominators of a diamond"
     (let* ((f (second (module-funcs
                        (in-ssa (lines "fun f (c : bool) : int = if c then 1 else 2"
                                       "val () = printInt (f (true))")))))
            (dom (ssa:dominance-of f))
            (joins (filter (lambda (b) (> (length (block-preds b)) 1)) (walk f))))
       (and (every (lambda (label) (ssa:dominates? dom (func-entry f) label))
                   (order-list f))
            (pair? joins)
            (every (lambda (join)
                     (equal? (hash-ref (ssa:dominance-idom dom) (block-label join))
                             (func-entry f)))
                   joins))))

   (test-assert "a phi names exactly its predecessors"
     (every (lambda (f)
              (every (lambda (b)
                       (every (lambda (p)
                                (equal? (sort (phi-preds p) string<?)
                                        (sort (block-preds b) string<?)))
                              (block-phis b)))
                     (walk f)))
            (module-funcs (in-ssa LOOP))))

   ;; -- the optimiser -----------------------------------------------------

   (test-equal "constants fold" '(10)
     (let ((m (in-ssa "val () = printInt (2 * 3 + 4)")))
       (optimise! m)
       (map i-const-value
            (filter (lambda (i) (is-a? i <i-const>))
                    (instructions (first (module-funcs m)))))))

   (test-assert "dead code goes"
     (let ((m (in-ssa (lines "fun f (n : int) : int = let val unused = n * n in n + 1 end"
                             "val () = printInt (f (2))"))))
       (optimise! m)
       (not (any (lambda (i) (and (is-a? i <i-bin>) (string=? (arith-op i) "*")))
                 (instructions (second (module-funcs m)))))))

   (test-equal "unreachable blocks go" '("wol_print")
     (let ((m (in-ssa "val () = if true then print (\"a\") else print (\"b\")")))
       (optimise! m)
       (map i-call-callee
            (filter (lambda (i) (is-a? i <i-call>))
                    (instructions (first (module-funcs m)))))))

   (test-assert "splitting leaves phis only after a jump"
     (let ((m (in-ssa LOOP #t)))
       (optimise! m)
       (every (lambda (f)
                (ssa:split-critical-edges! f)
                (ssa:verify f)
                (every (lambda (b)
                         (or (<= (length (succs b)) 1)
                             (every (lambda (s) (null? (block-phis (block-of f s))))
                                    (succs b))))
                       (walk f)))
              (module-funcs m))))

   ;; -- the tiles ---------------------------------------------------------

   (test-assert "multiply-add is one instruction"
     (let ((chosen (forms (function "a + b * c"))))
       (and (member "madd" chosen) (not (member "mul" chosen)))))

   (test-assert "multiply-subtract is one instruction"
     (let ((chosen (forms (function "a - b * c"))))
       (and (member "msub" chosen) (not (member "mul" chosen)))))

   ;; `a + b * 8` is one instruction with a shift and two as a multiply-add.
   (test-assert "a shifted operand beats a multiply-add"
     (let ((chosen (forms (function "a + b * 8"))))
       (and (= 1 (count-of chosen "adds"))
            (not (member "madd" chosen))
            (not (member "lsli" chosen)))))

   (test-equal "a small constant is an immediate" '("addi") (forms (function "a + 5")))
   (test-equal "and so is the next one" '("addi" "subi") (forms (function "(a + 5) - 7")))

   (test-assert "a large constant is not"
     (member "const" (forms (function "a + 100000"))))

   (test-assert "a multiply by a power of two is a shift"
     (let ((chosen (forms (function "a * 8"))))
       (and (member "lsli" chosen) (not (member "mul" chosen)))))

   (test-assert "a comparison read only by its branch sets the flags"
     (let* ((source (lines "fun f (a : int) : int = if a < 3 then 1 else 2"
                           "val () = printInt (f (1))"))
            (codes (append-map
                    (lambda (f)
                      (filter-map (lambda (b)
                                    (let ((t (terminator b)))
                                      (and (is-a? t <i-cbr>) (i-cbr-code t))))
                                  (walk f)))
                    (module-funcs (selected source)))))
       (and (member "lt" codes) (not (member "cset" (forms source))))))

   (test-assert "a comparison read by something else is a value"
     (member "cset" (forms "fun f (a : int) : bool = a < 3\nval () = print (\"x\")")))

   (test-equal "an array element takes two instructions" 2
     (let ((text (compile-to-asm "val a = array (4, 0)\nval () = printInt (a[2] + a[3])"
                                 (options #f #t #f))))
       (length (filter (lambda (l) (string-prefix? "\tldr " l))
                       (string-split text #\newline)))))

   ;; -- what the plan is for ----------------------------------------------

   ;; A constant costs nothing to repeat, so two readers may both take it.
   (test-assert "a constant read twice is still an immediate"
     (let ((chosen (forms (function "(a + 1) * (b + 1)"))))
       (and (= 2 (count-of chosen "addi")) (not (member "const" chosen)))))

   ;; Folding a whole spine would keep every term live until the end.
   (test-assert "a chain of additions is not deferred to its last line"
     (let* ((m (selected
                (lines "fun sum (a : int, b : int, c : int, d : int, e : int, f : int) : int ="
                       "  a + b + c + d + e + f"
                       "val () = printInt (sum (1, 2, 3, 4, 5, 6))")))
            (f (func-named m "sum")))
       (<= (pressure f (analyse f)) 8)))

   (test-equal "a node read twice is computed once" 1
     (count-of (forms (function "let val t = a * b in t + t end")) "mul"))

   (test-assert "the graph counts its readers"
     (let* ((f (func-named (selected (function "a + b")) "f"))
            (l (analyse f)))
       (every
        (lambda (b)
          (let ((g (build b (live-out l (block-label b)))))
            (every (lambda (n)
                     (= (node-users n)
                        (length (filter (lambda (o) (eqv? o (node-index n)))
                                        (append-map node-operands
                                                    (vector->list (dag-nodes g)))))))
                   (vector->list (dag-nodes g)))))
        (walk f))))

   (test-assert "selection keeps it in SSA"
     (begin (for-each ssa:verify (module-funcs (selected (function "a + b * c + 8") #t)))
            #t))))

;;; The allocator, the parallel copies, and what the emitter does with them.

(use-modules (oop goops)
             ((srfi srfi-1) #:select (first second find any every append-map
                                      delete-duplicates))
             (srfi srfi-64)
             (ice-9 format)
             (harness)
             (wolv parser)
             (wolv typecheck)
             (wolv ir)
             (wolv liveness)
             (wolv opt)
             (wolv select)
             (wolv outofssa)
             (wolv copies)
             (wolv registers)
             (wolv regset)
             ((wolv driver) #:select (compile-to-asm options default-options))
             ((wolv allocator) #:prefix alloc:)
             ((wolv lower) #:prefix low:)
             ((wolv ssa) #:prefix ssa:))

(define SOURCE
  (lines "type point = { x : int, y : int }"
         ""
         "fun busy (n : int) : int ="
         "  let"
         "    var a = n + 1"
         "    var b = n + 2"
         "    var c = n + 3"
         "    var d = n + 4"
         "    var total = 0"
         "  in"
         "    while a < n * 10 do ("
         "      total := total + a * b + c * d;"
         "      a := a + 1;"
         "      b := b + 2;"
         "      c := c + 3;"
         "      d := d + 4"
         "    );"
         "    total"
         "  end"
         ""
         "fun caller (n : int) : int = busy (n) + busy (n + 1) + busy (n + 2)"
         ""
         "val p = point { x = 1, y = 2 }"
         "val () = printInt (caller (3) + p.x)"))

;; The pipeline up to the point where the allocator takes over.
(define* (prepared #:optional (source SOURCE))
  (let ((prog (parse source)))
    (check prog)
    (let ((m (low:lower prog (low:options #t))))
      (ssa:construct-module! m)
      (optimise! m)
      (for-each ssa:split-critical-edges! (module-funcs m))
      (destruct-module! m)
      m)))

(define (each-func m allocs f)
  (for-each (lambda (func) (f func (hash-ref allocs (func-label func))))
            (module-funcs m)))

(define (instructions func) (append-map instrs (walk func)))

(define (moves-left m allocs)
  (length
   (append-map
    (lambda (func)
      (let ((c (allocation-colours (hash-ref allocs (func-label func)))))
        (filter (lambda (i)
                  (and (is-a? i <i-move>)
                       (not (eqv? (hash-ref c (instr-dst i))
                                  (hash-ref c (i-move-src i))))))
                (instructions func))))
    (module-funcs m))))

(define (colour-values alloc)
  (hash-fold (lambda (r c acc) (cons c acc)) '() (allocation-colours alloc)))

;; -- parallel copies ---------------------------------------------------------

;; Run a parallel copy on a register file and insist the permutation came out
;; right.  This is what caught a swap the ordering was doing twice.
(define (perform steps state)
  (let loop ((steps steps) (state state))
    (cond
     ((null? steps) state)
     ((mov? (car steps))
      (loop (cdr steps)
            (acons (mov-dst (car steps)) (assv-ref state (mov-src (car steps))) state)))
     (else
      (let ((a (swap-a (car steps)))
            (b (swap-b (car steps))))
        (loop (cdr steps)
              (acons b (assv-ref state a) (acons a (assv-ref state b) state))))))))

(define (worked moves borrowed)
  (let* ((before (map (lambda (r) (cons r (format #f "v~a" r))) (iota 32)))
         (steps (sequentialize moves borrowed))
         (after (perform steps before)))
    (for-each (lambda (m)
                (test-equal (format #f "x~a should hold v~a" (car m) (cdr m))
                  (assv-ref before (cdr m))
                  (assv-ref after (car m))))
              moves)
    steps))

(with-suite
 "allocator"
 (lambda ()

   ;; -- what the colouring promises --------------------------------------

   (test-assert "every value gets a colour"
     (let* ((m (prepared))
            (allocs (alloc:allocate-module m (whole-machine))))
       (each-func m allocs
                  (lambda (func alloc)
                    (let ((colours (allocation-colours alloc)))
                      (for-each (lambda (i)
                                  (for-each (lambda (r)
                                              (test-assert "a use has a colour"
                                                (hash-ref colours r #f)))
                                            (uses i))
                                  (when (defs i)
                                    (test-assert "a definition has a colour"
                                      (hash-ref colours (defs i) #f))))
                                (instructions func)))))
       #t))

   (test-assert "values live together differ"
     (let* ((m (prepared))
            (allocs (alloc:allocate-module m (whole-machine))))
       (each-func m allocs alloc:verify)
       #t))

   ;; One colour for everything is wrong, and has to be said so.  Without this,
   ;; weakening the verifier enough to accept a coalesced copy would go
   ;; unnoticed if it also stopped saying anything at all.
   (test-assert "the verifier rejects a real clash"
     (let* ((m (prepared))
            (allocs (alloc:allocate-module m (whole-machine))))
       (each-func
        m allocs
        (lambda (func alloc)
          (let ((colours (allocation-colours alloc)))
            (when (> (length (delete-duplicates (colour-values alloc))) 1)
              (let ((flat (make-hash-table)))
                (hash-for-each (lambda (r c) (hash-set! flat r 0)) colours)
                (test-assert "one colour for everything is rejected"
                  (catch #t
                    (lambda ()
                      (alloc:verify func (allocation flat (allocation-saved alloc)
                                                     (allocation-spilled alloc)))
                      #f)
                    (lambda args #t))))))))
       #t))

   ;; Both ends of a copy are live after it, and hold the same value.
   ;; Coalescing gives them one register, so a verifier that read a whole live
   ;; set and complained would reject every program it had worked on.
   (test-assert "the verifier accepts a coalesced copy"
     (let* ((func (new-func "f" "f" 0))
            (entry (add-block! func "entry"))
            (a (new-reg! func))
            (b (new-reg! func))
            (colours (make-hash-table)))
       (emit! entry (i-const a 1))
       (emit! entry (i-move b a))
       (emit! entry (i-call #f "wol_print_int" (list a)))
       (emit! entry (i-ret b))
       (recompute-preds! func)
       (hash-set! colours a 9)
       (hash-set! colours b 9)
       (alloc:verify func (allocation colours '() (make-hash-table)))
       #t))

   (test-assert "a value live across a call is callee-saved"
     (let* ((m (prepared))
            (allocs (alloc:allocate-module m (whole-machine))))
       (every (lambda (func)
                (let ((colours (allocation-colours
                                (hash-ref allocs (func-label func)))))
                  (every (lambda (r) (memv (hash-ref colours r) CALLEE-SAVED))
                         (regset->list (across-calls func (analyse func))))))
              (module-funcs m))))

   (test-assert "only the callee-saved it used are saved"
     (let* ((m (prepared))
            (allocs (alloc:allocate-module m (whole-machine))))
       (every (lambda (func)
                (let ((alloc (hash-ref allocs (func-label func))))
                  (equal? (allocation-saved alloc)
                          (sort (delete-duplicates
                                 (filter (lambda (c) (memv c CALLEE-SAVED))
                                         (colour-values alloc)))
                                <))))
              (module-funcs m))))

   (test-assert "a smaller machine still works"
     (every
      (lambda (size)
        (let* ((machine (limited size))
               (m (prepared))
               (allocs (alloc:allocate-module m machine)))
          (every (lambda (func)
                   (let ((alloc (hash-ref allocs (func-label func))))
                     (alloc:verify func alloc)
                     (every (lambda (c) (memv c (anywhere machine)))
                            (colour-values alloc))))
                 (module-funcs m))))
      '(5 6 8 12 16 26)))

   (test-assert "a small machine spills"
     (let* ((m (prepared))
            (allocs (alloc:allocate-module m (limited 6))))
       (and (any (lambda (func)
                   (> (hash-count (const #t)
                                  (allocation-spilled (hash-ref allocs (func-label func))))
                      0))
                 (module-funcs m))
            (every (lambda (func)
                     (let ((alloc (hash-ref allocs (func-label func))))
                       (hash-fold (lambda (r slot acc) (and acc (< slot (func-nslots func))))
                                  #t (allocation-spilled alloc))))
                   (module-funcs m)))))

   (test-assert "pressure falls to what the machine has"
     (let* ((machine (limited 5))
            (m (prepared))
            (allocs (alloc:allocate-module m machine)))
       (every (lambda (func) (<= (pressure func (analyse func)) (register-count machine)))
              (module-funcs m))))

   (test-assert "an impossible demand is reported"
     (let ((m (prepared
               (lines "fun ten (a : int, b : int, c : int, d : int, e : int,"
                      "         f : int, g : int, h : int, i : int, j : int) : int = a + j"
                      "val () = printInt (ten (1, 2, 3, 4, 5, 6, 7, 8, 9, 10))"))))
       (catch 'wolv-out-of-registers
         (lambda () (alloc:allocate-module m (limited 8)) #f)
         (lambda (key message) (and (string-contains message "more registers") #t)))))

   ;; -- what coalescing is for --------------------------------------------

   (test-assert "leaving SSA removes every phi"
     (every (lambda (func) (every (lambda (b) (null? (block-phis b))) (walk func)))
            (module-funcs (prepared))))

   (test-assert "leaving SSA makes copies and coalescing eats them"
     (let* ((m (prepared))
            (before (length (filter (lambda (i) (is-a? i <i-move>))
                                    (append-map instructions (module-funcs m))))))
       (and (> before 0)
            (let ((allocs (alloc:allocate-module m (whole-machine))))
              (<= (moves-left m allocs) (quotient before 10))))))

   ;; -- parallel copies ---------------------------------------------------

   (test-assert "a copy with no cycle is just moves"
     (let ((steps (worked '((1 . 2) (3 . 4) (5 . 5)) 9)))
       (and (every mov? steps) (= 2 (length steps)))))

   (test-assert "a chain is ordered so nothing is lost"
     (begin (worked '((1 . 2) (2 . 3) (3 . 4)) 9) #t))

   (test-assert "a cycle borrows a register when there is one"
     (let ((steps (worked '((1 . 2) (2 . 1)) 9)))
       (and (every mov? steps) (any (lambda (s) (eqv? (mov-dst s) 9)) steps))))

   (test-assert "a cycle swaps when there is nothing to borrow"
     (let ((steps (worked '((1 . 2) (2 . 1)) #f)))
       (equal? (map swap? steps) '(#t))))

   (test-assert "a longer cycle swaps its way round"
     (let ((steps (worked '((1 . 2) (2 . 3) (3 . 1)) #f)))
       (and (every swap? steps) (= 2 (length steps)))))

   (test-assert "two cycles at once"
     (begin (worked '((1 . 2) (2 . 1) (3 . 4) (4 . 3)) #f)
            (worked '((1 . 2) (2 . 1) (3 . 4) (4 . 3)) 9)
            #t))

   ;; -- what the scratch registers used to be for -------------------------

   (test-assert "the remainder is a divide and an msub"
     (let ((text (compile-to-asm
                  "fun f (a : int, b : int) : int = a mod b\nval () = printInt (f (7, 2))"
                  (default-options))))
       (and (= 1 (length (filter (lambda (l) (string-contains l "sdiv"))
                                 (string-split text #\newline))))
            (= 1 (length (filter (lambda (l) (string-contains l "msub"))
                                 (string-split text #\newline))))
            (not (string-contains text "mul")))))

   ;; x17 is only for an address the emitter cannot reach any other way.
   (test-assert "ordinary code keeps no register back"
     (not (string-contains (compile-to-asm (read-file "examples/tour.wol")
                                           (default-options))
                           "x17")))

   ;; It used to be held back for the emitter; a busy function should take it.
   (test-assert "x16 is allocatable"
     (string-contains (compile-to-asm (read-file "test/programs/pressure.wol")
                                      (default-options))
                      "x16"))))

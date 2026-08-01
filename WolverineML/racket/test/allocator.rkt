#lang racket/base

;; The allocator, the parallel copies, and what the emitter does with them.

(require rackunit
         racket/list
         racket/set
         racket/file
         racket/string
         racket/runtime-path
         data/gvector
         "../src/parser.rkt"
         (prefix-in types: "../src/typecheck.rkt")
         (prefix-in alloc: "../src/allocator.rkt")
         (prefix-in copies: "../src/copies.rkt")
         (prefix-in driver: "../src/driver.rkt")
         (prefix-in graph: "../src/graph.rkt")
         (prefix-in ir: "../src/ir.rkt")
         (prefix-in live: "../src/liveness.rkt")
         (prefix-in low: "../src/lower.rkt")
         (prefix-in opt: "../src/opt.rkt")
         (prefix-in out: "../src/outofssa.rkt")
         (prefix-in reg: "../src/registers.rkt")
         (prefix-in sel: "../src/select.rkt")
         (prefix-in spill: "../src/spill.rkt")
         (prefix-in ssa: "../src/ssa.rkt"))

(provide allocator-tests)

(define-runtime-path TOUR "../examples/tour.wol")
(define-runtime-path PRESSURE "programs/pressure.wol")

(define SOURCE #<<END
type point = { x : int, y : int }

fun busy (n : int) : int =
  let
    var a = n + 1
    var b = n + 2
    var c = n + 3
    var d = n + 4
    var total = 0
  in
    while a < n * 10 do (
      total := total + a * b + c * d;
      a := a + 1;
      b := b + 2;
      c := c + 3;
      d := d + 4
    );
    total
  end

fun caller (n : int) : int = busy (n) + busy (n + 1) + busy (n + 2)

val p = point { x = 1, y = 2 }
val () = printInt (caller (3) + p.x)
END
  )

;; The pipeline up to the point where the allocator takes over.
(define (prepared [source SOURCE])
  (define prog (parse source))
  (types:check prog)
  (define m (low:lower prog (low:options #t)))
  (ssa:construct-module! m)
  (opt:optimise! m)
  (for ([f (in-list (ir:module*-funcs m))]) (ssa:split-critical-edges! f))
  (out:destruct-module! m)
  m)

;; The module, and what the allocator decided about each function of it.
(define (allocated [machine (reg:whole-machine)] [source SOURCE])
  (define m (prepared source))
  (values m (alloc:allocate-module m machine)))

(define (each-func m allocs f)
  (for ([func (in-list (ir:module*-funcs m))])
    (f func (hash-ref allocs (ir:func-label func)))))

(define (instructions func)
  (for*/list ([b (in-list (ir:walk func))] [i (in-list (ir:instrs b))]) i))

(define (moves-left m allocs)
  (for*/sum ([func (in-list (ir:module*-funcs m))]
             [i (in-list (instructions func))]
             #:when (and (ir:i:move? i)
                         (let ([c (ir:allocation-colours (hash-ref allocs (ir:func-label func)))])
                           (not (eqv? (hash-ref c (ir:i:move-dst i))
                                      (hash-ref c (ir:i:move-src i)))))))
    1))

;; -- parallel copies ---------------------------------------------------------

;; Run a parallel copy on a register file and insist the permutation came out
;; right.  This is what caught a swap the ordering was doing twice.
(define (perform steps state)
  (for/fold ([state state]) ([step (in-list steps)])
    (cond
      [(copies:mov? step)
       (hash-set state (copies:mov-dst step) (hash-ref state (copies:mov-src step)))]
      [else
       (define a (copies:swap-a step))
       (define b (copies:swap-b step))
       (hash-set (hash-set state a (hash-ref state b)) b (hash-ref state a))])))

(define (worked moves borrowed)
  (define before (for/hasheqv ([r (in-range 32)]) (values r (format "v~a" r))))
  (define steps (copies:sequentialize moves borrowed))
  (define after (perform steps before))
  (for ([m (in-list moves)])
    (check-equal? (hash-ref after (car m)) (hash-ref before (cdr m))
                  (format "x~a should hold v~a" (car m) (cdr m))))
  steps)

(define allocator-tests
  (test-suite
   "allocator"

   ;; -- what the colouring promises -------------------------------------

   (test-case "every value gets a colour"
     (define-values (m allocs) (allocated))
     (each-func m allocs
                (λ (func alloc)
                  (define colours (ir:allocation-colours alloc))
                  (for ([i (in-list (instructions func))])
                    (for ([r (in-list (ir:uses i))]) (check-true (and (hash-ref colours r #f) #t)))
                    (when (ir:defs i)
                      (check-true (and (hash-ref colours (ir:defs i) #f) #t)))))))

   (test-case "values live together differ"
     (define-values (m allocs) (allocated))
     (each-func m allocs alloc:verify))

   (test-case "the verifier rejects a real clash"
     ;; One colour for everything is wrong, and has to be said so.  Without
     ;; this, weakening the verifier enough to accept a coalesced copy would go
     ;; unnoticed if it also stopped saying anything at all.
     (define-values (m allocs) (allocated))
     (each-func
      m allocs
      (λ (func alloc)
        (define colours (ir:allocation-colours alloc))
        (when (> (set-count (list->seteqv (hash-values colours))) 1)
          (check-exn #rx"at once"
                     (λ ()
                       (alloc:verify func
                                     (ir:allocation
                                      (for/hasheqv ([r (in-hash-keys colours)]) (values r 0))
                                      (ir:allocation-saved alloc)
                                      (ir:allocation-spilled alloc)))))))))

   (test-case "the verifier accepts a coalesced copy"
     ;; Both ends of a copy are live after it, and hold the same value.
     ;; Coalescing gives them one register, so a verifier that read a whole live
     ;; set and complained would reject every program it had worked on.
     (define func (ir:new-func "f" "f" 0))
     (define entry (ir:add-block! func "entry"))
     (define a (ir:new-reg! func))
     (define b (ir:new-reg! func))
     (ir:emit! entry (ir:i:const a 1))
     (ir:emit! entry (ir:i:move b a))
     (ir:emit! entry (ir:i:call #f "wol_print_int" (list a)))
     (ir:emit! entry (ir:i:ret b))
     (ir:recompute-preds! func)
     (alloc:verify func (ir:allocation (hasheqv a 9 b 9) '() (hasheqv))))

   (test-case "a value live across a call is callee-saved"
     (define-values (m allocs) (allocated))
     (each-func m allocs
                (λ (func alloc)
                  (define colours (ir:allocation-colours alloc))
                  (for ([r (in-list (live:sorted-regs
                                     (live:across-calls func (live:analyse func))))])
                    (check-true (and (memv (hash-ref colours r) reg:CALLEE-SAVED) #t))))))

   (test-case "only the callee-saved it used are saved"
     (define-values (m allocs) (allocated))
     (each-func m allocs
                (λ (func alloc)
                  (check-equal?
                   (list->seteqv (ir:allocation-saved alloc))
                   (set-intersect (list->seteqv (hash-values (ir:allocation-colours alloc)))
                                  (list->seteqv reg:CALLEE-SAVED))))))

   (test-case "a smaller machine still works"
     (for ([size (in-list '(5 6 8 12 16 26))])
       (define machine (reg:limited size))
       (define-values (m allocs) (allocated machine))
       (each-func m allocs
                  (λ (func alloc)
                    (alloc:verify func alloc)
                    (for ([colour (in-list (hash-values (ir:allocation-colours alloc)))])
                      (check-true (and (memv colour (reg:anywhere machine)) #t)))))))

   (test-case "a small machine spills"
     (define-values (m allocs) (allocated (reg:limited 6)))
     (check-true (for/or ([func (in-list (ir:module*-funcs m))])
                   (positive? (hash-count (ir:allocation-spilled
                                           (hash-ref allocs (ir:func-label func))))))
                 "nothing spilled")
     (each-func m allocs
                (λ (func alloc)
                  (for ([slot (in-list (hash-values (ir:allocation-spilled alloc)))])
                    (check-true (< slot (ir:func-nslots func)))))))

   (test-case "pressure falls to what the machine has"
     (define machine (reg:limited 5))
     (define-values (m allocs) (allocated machine))
     (for ([func (in-list (ir:module*-funcs m))])
       (check-true (<= (live:pressure func (live:analyse func))
                       (reg:register-count machine)))))

   (test-case "an impossible demand is reported"
     (define m (prepared (string-append
                          "fun ten (a : int, b : int, c : int, d : int, e : int,\n"
                          "         f : int, g : int, h : int, i : int, j : int) : int = a + j\n"
                          "val () = printInt (ten (1, 2, 3, 4, 5, 6, 7, 8, 9, 10))\n")))
     (check-exn (λ (e) (and (spill:exn:out-of-registers? e)
                            (regexp-match? #rx"more registers" (exn-message e))))
                (λ () (alloc:allocate-module m (reg:limited 8)))))

   ;; -- what coalescing is for -------------------------------------------

   (test-case "leaving SSA removes every phi"
     (for* ([func (in-list (ir:module*-funcs (prepared)))] [b (in-list (ir:walk func))])
       (check-true (null? (ir:block-phis b)))))

   (test-case "leaving SSA makes copies and coalescing eats them"
     (define m (prepared))
     (define before
       (for*/sum ([func (in-list (ir:module*-funcs m))]
                  [i (in-list (instructions func))]
                  #:when (ir:i:move? i))
         1))
     (check-true (> before 0) "leaving SSA should have made copies")
     (define allocs (alloc:allocate-module m (reg:whole-machine)))
     (check-true (<= (moves-left m allocs) (quotient before 10))
                 (format "~a of ~a copies survived" (moves-left m allocs) before)))

   ;; -- parallel copies --------------------------------------------------

   (test-case "a copy with no cycle is just moves"
     (define steps (worked '((1 . 2) (3 . 4) (5 . 5)) 9))
     (check-true (andmap copies:mov? steps))
     (check-equal? (length steps) 2))

   (test-case "a chain is ordered so nothing is lost"
     (worked '((1 . 2) (2 . 3) (3 . 4)) 9))

   (test-case "a cycle borrows a register when there is one"
     (define steps (worked '((1 . 2) (2 . 1)) 9))
     (check-true (andmap copies:mov? steps))
     (check-true (for/or ([s (in-list steps)]) (eqv? (copies:mov-dst s) 9))))

   (test-case "a cycle swaps when there is nothing to borrow"
     (define steps (worked '((1 . 2) (2 . 1)) #f))
     (check-equal? (map copies:swap? steps) '(#t)))

   (test-case "a longer cycle swaps its way round"
     (define steps (worked '((1 . 2) (2 . 3) (3 . 1)) #f))
     (check-true (andmap copies:swap? steps))
     (check-equal? (length steps) 2))

   (test-case "two cycles at once"
     (worked '((1 . 2) (2 . 1) (3 . 4) (4 . 3)) #f)
     (worked '((1 . 2) (2 . 1) (3 . 4) (4 . 3)) 9))

   ;; -- what the scratch registers used to be for ------------------------

   (test-case "the remainder is a divide and an msub"
     (define text (driver:compile-to-asm
                   "fun f (a : int, b : int) : int = a mod b\nval () = printInt (f (7, 2))"
                   (driver:default-options)))
     (check-equal? (length (regexp-match* #rx"sdiv" text)) 1)
     (check-equal? (length (regexp-match* #rx"msub" text)) 1)
     (check-false (regexp-match? #rx"mul" text)))

   (test-case "ordinary code keeps no register back"
     ;; x17 is only for an address the emitter cannot reach any other way.
     (check-false (regexp-match? #rx"x17" (driver:compile-to-asm (file->string TOUR)
                                                                (driver:default-options)))))

   (test-case "x16 is allocatable"
     ;; It used to be held back for the emitter; a busy function should take it.
     (check-true (regexp-match? #rx"x16" (driver:compile-to-asm (file->string PRESSURE)
                                                               (driver:default-options)))))))

(module+ test (require rackunit/text-ui) (void (run-tests allocator-tests)))

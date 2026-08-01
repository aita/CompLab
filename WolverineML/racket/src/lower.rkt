#lang racket/base

;; Lowering: the typed syntax tree becomes a control flow graph.
;;
;; Two things are worth knowing about this pass.
;;
;; It never builds a phi.  A variable written in two branches is written to the
;; same register twice, and `ssa.rkt` is what turns those two writes into one
;; phi.  Lowering only has to make sure a definition reaches every use, which
;; structured control flow does for free.
;;
;; It decides where a variable lives.  A variable the checker did not mark as
;; escaping becomes a register; one that escaped becomes a frame slot, reached
;; through `i:load-slot`/`i:store-slot` in its own function and through a chain
;; of static links from a nested one.

(require racket/list
         data/gvector
         "types.rkt"
         (prefix-in ast: "ast.rkt")
         (prefix-in ir: "ir.rkt"))

(provide (struct-out options) lower)

(struct options (checks?) #:transparent)

;; -- what the whole module shares --------------------------------------------

;; String literals and the function list.  `symbols` maps a literal to the
;; symbol it was given, so the same text is emitted once.
(struct lowerer (opts mod symbols) #:transparent)

(define (intern! up text)
  (or (hash-ref (lowerer-symbols up) text #f)
      (let ([symbol (format ".Lstr~a" (hash-count (lowerer-symbols up)))])
        (hash-set! (lowerer-symbols up) text symbol)
        (ir:set-module*-strings! (lowerer-mod up)
                                 (append (ir:module*-strings (lowerer-mod up))
                                         (list (ir:string-lit symbol text))))
        symbol)))

(define (add-func! up f)
  (ir:set-module*-funcs! (lowerer-mod up)
                         (append (ir:module*-funcs (lowerer-mod up)) (list f))))

;; -- one function ------------------------------------------------------------

;; `breaks` is the stack of blocks a `break` jumps to, and `children?` says
;; whether anything is nested inside, which is what decides if the static link
;; can be dropped.
(struct fl (up opts func [cur #:mutable] [breaks #:mutable]
               [counter #:mutable] [children? #:mutable])
  #:transparent)

(define (new-fl up label name depth)
  (define f (ir:new-func label name depth))
  (define me (fl up (lowerer-opts up) f (ir:add-block! f "entry") '() 0 #f))
  (when (> depth 0) (ir:set-func-link-slot! f (ir:new-slot! f)))
  (add-func! up f)
  me)

;; -- block plumbing ----------------------------------------------------------

(define (fresh! me hint)
  (set-fl-counter! me (add1 (fl-counter me)))
  (ir:add-block! (fl-func me) (format "~a~a" hint (fl-counter me))))

(define (emit! me i) (ir:emit! (fl-cur me) i))

(define (terminate! me t)
  (emit! me t)
  (set-fl-cur! me (fresh! me "dead")))

(define (jump! me b) (terminate! me (ir:i:jmp (ir:block-label b))))

(define (branch! me cnd yes no)
  (terminate! me (ir:i:cbr cnd (ir:block-label yes) (ir:block-label no) "")))

(define (reg! me) (ir:new-reg! (fl-func me)))

(define (const! me value)
  (define r (reg! me))
  (emit! me (ir:i:const r value))
  r)

;; -- function bodies ---------------------------------------------------------

(define (top-level! me decls)
  (lower-decls! me decls)
  (terminate! me (ir:i:ret #f))
  (finish! me))

(define (function-body! me bind sym)
  (define f (fl-func me))
  (when (> (ir:func-depth f) 0)
    (define link (reg! me))
    (gvector-add! (ir:func-params f) link)
    (emit! me (ir:i:store-slot (ir:func-link-slot f) link)))
  (for ([psym (in-list (fun-sym-params sym))]
        [index (in-naturals (gvector-count (ir:func-params f)))])
    (cond
      ;; The ninth argument and beyond is already in the frame when the callee
      ;; starts, at a negative slot, so it never takes a register at entry.
      [(>= index ir:ARGUMENT-REGISTERS)
       (set-var-sym-escapes?! psym #t)
       (set-var-sym-home! psym (in-frame (- (add1 (- index ir:ARGUMENT-REGISTERS)))))]
      [else
       (define r (reg! me))
       (gvector-add! (ir:func-params f) r)
       (cond
         [(var-sym-escapes? psym)
          (define slot (ir:new-slot! f))
          (set-var-sym-home! psym (in-frame slot))
          (emit! me (ir:i:store-slot slot r))]
         [else (set-var-sym-home! psym (in-register r))])]))
  (define value (lower-exp me (ast:fun-bind-body bind)))
  (terminate! me (ir:i:ret (and (not (eq? (fun-sym-result sym) 'unit)) value)))
  (finish! me))

(define (finish! me)
  (ir:drop-unreachable! (fl-func me))
  (drop-unused-link! me))

;; A function nobody nests inside, and that never looks outward, keeps no static
;; link: the slot goes, and every later slot moves down one.
(define (drop-unused-link! me)
  (define f (fl-func me))
  (define slot (ir:func-link-slot f))
  (define (moved s) (if (> s slot) (sub1 s) s))
  (unless (or (< slot 0)
              (fl-children? me)
              (for*/or ([b (in-list (ir:walk f))] [i (in-list (ir:instrs b))])
                (and (ir:i:load-slot? i) (= (ir:i:load-slot-slot i) slot))))
    (for ([b (in-list (ir:walk f))])
      (ir:set-instrs!
       b
       (for/list ([i (in-list (ir:instrs b))]
                  #:unless (and (ir:i:store-slot? i) (= (ir:i:store-slot-slot i) slot)))
         (cond
           [(ir:i:store-slot? i)
            (ir:i:store-slot (moved (ir:i:store-slot-slot i)) (ir:i:store-slot-src i))]
           [(ir:i:load-slot? i)
            (ir:i:load-slot (ir:i:load-slot-dst i) (moved (ir:i:load-slot-slot i)))]
           [else i]))))
    (ir:set-func-nslots! f (sub1 (ir:func-nslots f)))
    (ir:set-func-link-slot! f -1)))

;; -- declarations ------------------------------------------------------------

(define (lower-decls! me decls)
  (for ([d (in-list decls)])
    (cond
      [(ast:d:type? d) (void)]
      [(ast:d:val? d) (val-decl! me d)]
      [else
       (set-fl-children?! me #t)
       (for ([b (in-list (ast:d:fun-binds d))])
         (define sym (ast:fun-bind-sym b))
         (function-body!
          (new-fl (fl-up me) (fun-sym-label sym) (fun-sym-name sym) (fun-sym-depth sym))
          b sym))])))

(define (val-decl! me d)
  (define value (lower-exp me (ast:d:val-init d)))
  (define sym (ast:d:val-sym d))
  (when (and sym (not (eq? (var-sym-ty sym) 'unit)))
    (bind! me sym value)))

;; Give a variable its home, and put the initial value in it.
(define (bind! me sym value)
  (cond
    [(var-sym-escapes? sym)
     (define slot (ir:new-slot! (fl-func me)))
     (set-var-sym-home! sym (in-frame slot))
     (emit! me (ir:i:store-slot slot value))]
    [else
     (define r (reg! me))
     (set-var-sym-home! sym (in-register r))
     (emit! me (ir:i:move r value))]))

;; -- reaching variables and frames -------------------------------------------

(define (var-reg sym) (in-register-reg (var-sym-home sym)))
(define (var-slot sym) (in-frame-slot (var-sym-home sym)))

;; A register holding the frame pointer of the function at `depth`.
(define (frame-at me depth)
  (define f (fl-func me))
  (define r (reg! me))
  (cond
    [(= depth (ir:func-depth f)) (emit! me (ir:i:frame-addr r)) r]
    [else
     (emit! me (ir:i:load-slot r (ir:func-link-slot f)))
     (let walk ([r r] [here (sub1 (ir:func-depth f))])
       (cond
         [(<= here depth) r]
         [else
          (define next (reg! me))
          (emit! me (ir:i:load next r (ir:slot-offset 0)))
          (walk next (sub1 here))]))]))

(define (read-var me sym)
  (cond
    [(not (var-sym-escapes? sym)) (var-reg sym)]
    [(= (var-sym-depth sym) (ir:func-depth (fl-func me)))
     (define r (reg! me))
     (emit! me (ir:i:load-slot r (var-slot sym)))
     r]
    [else
     (define base (frame-at me (var-sym-depth sym)))
     (define r (reg! me))
     (emit! me (ir:i:load r base (ir:slot-offset (var-slot sym))))
     r]))

(define (write-var! me sym value)
  (cond
    [(not (var-sym-escapes? sym)) (emit! me (ir:i:move (var-reg sym) value))]
    [(= (var-sym-depth sym) (ir:func-depth (fl-func me)))
     (emit! me (ir:i:store-slot (var-slot sym) value))]
    [else
     (define base (frame-at me (var-sym-depth sym)))
     (emit! me (ir:i:store base (ir:slot-offset (var-slot sym)) value))]))

;; -- expressions -------------------------------------------------------------

(define (value me e)
  (or (lower-exp me e) (error 'lower "expected a value here")))

(define (lower-exp me e)
  (define n (ast:exp-node e))
  (cond
    [(ast:e:int? n) (const! me (ast:e:int-value n))]
    [(ast:e:bool? n) (const! me (if (ast:e:bool-value n) 1 0))]
    [(ast:e:nil? n) (const! me 0)]
    [(ast:e:unit? n) #f]
    [(ast:e:str? n)
     (define r (reg! me))
     (emit! me (ir:i:str-const r (intern! (fl-up me) (ast:e:str-value n))))
     r]
    [(ast:e:var? n) (read-var me (ast:exp-sym e))]
    [(ast:e:call? n) (call-exp me e n)]
    [(ast:e:record? n) (record-lit me e n)]
    [(ast:e:index? n)
     (define addr (element-address me n))
     (define r (reg! me))
     (emit! me (ir:i:load r addr ir:WORD))
     r]
    [(ast:e:field? n) (field-exp me e n)]
    [(ast:e:neg? n)
     (define zero (const! me 0))
     (binop! me "-" zero (value me (ast:e:neg-operand n)))]
    [(ast:e:bin? n) (bin-exp me e n)]
    [(ast:e:logic? n) (logic-exp me n)]
    [(ast:e:assign? n) (assign! me n) #f]
    [(ast:e:if? n) (if-exp me e n)]
    [(ast:e:while? n) (while-exp! me n) #f]
    [(ast:e:for? n) (for-exp! me e n) #f]
    [(ast:e:break? n) (terminate! me (ir:i:jmp (car (fl-breaks me)))) #f]
    [(ast:e:seq? n)
     (for/fold ([last #f]) ([item (in-list (ast:e:seq-items n))]) (lower-exp me item))]
    [else
     (lower-decls! me (ast:e:let-decls n))
     (lower-exp me (ast:e:let-body n))]))

(define (binop! me op lhs rhs)
  (define r (reg! me))
  (emit! me (ir:i:bin r op lhs rhs))
  r)

(define (compare! me op lhs rhs)
  (define r (reg! me))
  (emit! me (ir:i:cmp r op lhs rhs))
  r)

(define (call-runtime! me name args)
  (define r (reg! me))
  (emit! me (ir:i:call r name args))
  r)

(define (bin-exp me e n)
  (define op (ast:e:bin-op n))
  (define lhs (value me (ast:e:bin-lhs n)))
  (define rhs (value me (ast:e:bin-rhs n)))
  (cond
    [(string=? op "^") (call-runtime! me "wol_concat" (list lhs rhs))]
    [(member op '("/" "mod"))
     (check-nonzero! me rhs)
     (cond
       [(string=? op "/") (binop! me "/" lhs rhs)]
       [else
        ;; The remainder is spelled out rather than left to the emitter: the
        ;; quotient it needs in between is a value like any other, and the
        ;; allocator can find it a register.  The emitter fuses the last two
        ;; back into one `msub`.
        (define quotient (binop! me "/" lhs rhs))
        (define product (binop! me "*" quotient rhs))
        (binop! me "-" lhs product)])]
    [(member op '("+" "-" "*")) (binop! me op lhs rhs)]
    [(eq? (ast:exp-ty (ast:e:bin-lhs n)) 'string)
     (define order (call-runtime! me "wol_string_cmp" (list lhs rhs)))
     (compare! me op order (const! me 0))]
    [else (compare! me op lhs rhs)]))

;; `andalso` and `orelse` are branches, so the result needs a register.
(define (logic-exp me n)
  (define result (reg! me))
  (define rhs-block (fresh! me "logic"))
  (define join (fresh! me "logicjoin"))
  (define lhs (value me (ast:e:logic-lhs n)))
  (emit! me (ir:i:move result lhs))
  (if (string=? (ast:e:logic-op n) "andalso")
      (branch! me lhs rhs-block join)
      (branch! me lhs join rhs-block))
  (set-fl-cur! me rhs-block)
  (emit! me (ir:i:move result (value me (ast:e:logic-rhs n))))
  (jump! me join)
  (set-fl-cur! me join)
  result)

(define (call-exp me e n)
  (define sym (ast:exp-sym e))
  (define args (ast:e:call-args n))
  (case (fun-sym-builtin sym)
    [("not") (binop! me "xor" (value me (first args)) (const! me 1))]
    [("array")
     (define count (value me (first args)))
     (define init (value me (second args)))
     (call-runtime! me "wol_array" (list count init))]
    [("length")
     (define arr (value me (first args)))
     (check-not-nil! me arr)
     (define r (reg! me))
     (emit! me (ir:i:load r arr 0))
     r]
    [else
     (define lowered (for/list ([a (in-list args)]) (value me a)))
     (define full
       (if (fun-sym-builtin sym)
           lowered
           (cons (frame-at me (sub1 (fun-sym-depth sym))) lowered)))
     (cond
       [(eq? (fun-sym-result sym) 'unit)
        (emit! me (ir:i:call #f (fun-sym-label sym) full))
        #f]
       [else (call-runtime! me (fun-sym-label sym) full)])]))

(define (record-lit me e n)
  (define rec (ast:exp-ty e))
  (define size (const! me (* ir:WORD (max (length (ty:record-fields rec)) 1))))
  (define base (call-runtime! me "wol_alloc" (list size)))
  (for ([f (in-list (ast:e:record-inits n))] [i (in-naturals)])
    (emit! me (ir:i:store base (* ir:WORD i) (value me (ast:field-init-value f)))))
  base)

;; The address of `a[i]`, without the length word the elements follow.
;;
;; The selector turns this into one `add` with a shifted operand, and the word is
;; the load's displacement, so the two instructions that come out are the two the
;; machine has.
(define (element-address me n)
  (define base (value me (ast:e:index-array n)))
  (define idx (value me (ast:e:index-index n)))
  (check-not-nil! me base)
  (check-bounds! me base idx)
  (binop! me "+" base (binop! me "shl" idx (const! me 3))))

(define (field-exp me e n)
  (define base (value me (ast:e:field-record n)))
  (check-not-nil! me base)
  (define r (reg! me))
  (emit! me (ir:i:load r base (* ir:WORD (ast:exp-offset e))))
  r)

(define (assign! me n)
  (define target (ast:e:assign-target n))
  (define t (ast:exp-node target))
  (cond
    [(ast:e:var? t) (write-var! me (ast:exp-sym target) (value me (ast:e:assign-value n)))]
    [(ast:e:index? t)
     (define addr (element-address me t))
     (emit! me (ir:i:store addr ir:WORD (value me (ast:e:assign-value n))))]
    [else
     (define base (value me (ast:e:field-record t)))
     (check-not-nil! me base)
     (emit! me (ir:i:store base (* ir:WORD (ast:exp-offset target))
                           (value me (ast:e:assign-value n))))]))

(define (if-exp me e n)
  (define result (and (not (eq? (ast:exp-ty e) 'unit)) (reg! me)))
  (define yes (fresh! me "then"))
  (define no (fresh! me "else"))
  (define join (fresh! me "join"))
  (branch! me (value me (ast:e:if-cond n)) yes no)

  (set-fl-cur! me yes)
  (let ([value (lower-exp me (ast:e:if-then n))])
    (when (and result value) (emit! me (ir:i:move result value))))
  (jump! me join)

  (set-fl-cur! me no)
  (when (ast:e:if-els n)
    (let ([value (lower-exp me (ast:e:if-els n))])
      (when (and result value) (emit! me (ir:i:move result value)))))
  (jump! me join)

  (set-fl-cur! me join)
  result)

(define (in-loop! me done thunk)
  (set-fl-breaks! me (cons (ir:block-label done) (fl-breaks me)))
  (thunk)
  (set-fl-breaks! me (cdr (fl-breaks me))))

(define (while-exp! me n)
  (define test (fresh! me "test"))
  (define body (fresh! me "body"))
  (define done (fresh! me "done"))
  (jump! me test)
  (set-fl-cur! me test)
  (branch! me (value me (ast:e:while-cond n)) body done)
  (set-fl-cur! me body)
  (in-loop! me done (λ () (lower-exp me (ast:e:while-body n))))
  (jump! me test)
  (set-fl-cur! me done))

;; `for i = lo to hi` counts up, and stops before overflowing at `hi`.
(define (for-exp! me e n)
  (define sym (ast:exp-sym e))
  (define lo (value me (ast:e:for-lo n)))
  (define hi-value (value me (ast:e:for-hi n)))
  (define hi (reg! me))
  (emit! me (ir:i:move hi hi-value))
  (bind! me sym lo)
  (define body (fresh! me "forbody"))
  (define step (fresh! me "forstep"))
  (define done (fresh! me "fordone"))
  (branch! me (compare! me "<=" lo hi) body done)

  (set-fl-cur! me body)
  (in-loop! me done (λ () (lower-exp me (ast:e:for-body n))))
  (branch! me (compare! me "<" (read-var me sym) hi) step done)

  (set-fl-cur! me step)
  (write-var! me sym (binop! me "+" (read-var me sym) (const! me 1)))
  (jump! me body)

  (set-fl-cur! me done))

;; -- run-time checks ---------------------------------------------------------

;; Each of the three is the same shape: a branch to a block that calls the
;; runtime and never comes back, and a block where the program carries on.
(define (guard! me hint test-reg bad-first? call)
  (define bad (fresh! me hint))
  (define ok (fresh! me "ok"))
  (if bad-first? (branch! me test-reg bad ok) (branch! me test-reg ok bad))
  (set-fl-cur! me bad)
  (emit! me call)
  (jump! me ok)
  (set-fl-cur! me ok))

(define (check-not-nil! me base)
  (when (options-checks? (fl-opts me))
    (guard! me "nil" (compare! me "=" base (const! me 0)) #t
            (ir:i:call #f "wol_nil_error" '()))))

(define (check-bounds! me base idx)
  (when (options-checks? (fl-opts me))
    (define len (reg! me))
    (emit! me (ir:i:load len base 0))
    (guard! me "oob" (compare! me "u<" idx len) #f
            (ir:i:call #f "wol_bounds_error" (list idx len)))))

(define (check-nonzero! me rhs)
  (when (options-checks? (fl-opts me))
    (guard! me "divzero" (compare! me "=" rhs (const! me 0)) #t
            (ir:i:call #f "wol_div_error" '()))))

;; -- the whole program -------------------------------------------------------

(define (lower prog [opts (options #t)])
  (define up (lowerer opts (ir:module* '() '()) (make-hash)))
  (top-level! (new-fl up "wol_main" "main" 0) prog)
  (lowerer-mod up))

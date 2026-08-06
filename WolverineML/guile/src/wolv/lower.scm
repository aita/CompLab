;;; Lowering: the typed syntax tree becomes a control flow graph.
;;;
;;; Two things are worth knowing about this pass.
;;;
;;; It never builds a phi.  A variable written in two branches is written to the
;;; same register twice, and `ssa.scm` is what turns those two writes into one
;;; phi.  Lowering only has to make sure a definition reaches every use, which
;;; structured control flow does for free.
;;;
;;; It decides where a variable lives.  A variable the checker did not mark as
;;; escaping becomes a register; one that escaped becomes a frame slot, reached
;;; through `<i-load-slot>`/`<i-store-slot>` in its own function and through a
;;; chain of static links from a nested one.
;;;
;;; `lower-exp` is a generic function: one method per node class, each answering
;;; with the register the value ended up in, or `#f` for a form with no value.

(define-module (wolv lower)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (first second any))
  #:use-module (ice-9 format)
  #:use-module (wolv types)
  #:use-module (wolv ast)
  #:use-module (wolv ir)
  #:export (<options> options options-checks? lower))

(define-class <options> ()
  (checks? #:init-keyword #:checks? #:getter options-checks?))

(define* (options #:optional (checks? #t)) (make <options> #:checks? checks?))

;; -- what the whole module shares --------------------------------------------

;; String literals and the function list.  `symbols` maps a literal to the
;; symbol it was given, so the same text is emitted once.
(define-class <lowerer> ()
  (opts #:init-keyword #:opts #:getter lowerer-opts)
  (mod #:init-keyword #:mod #:getter lowerer-mod)
  (symbols #:init-thunk make-hash-table #:getter lowerer-symbols))

(define (intern! up text)
  (or (hash-ref (lowerer-symbols up) text #f)
      (let ((symbol (format #f ".Lstr~a" (hash-count (const #t) (lowerer-symbols up)))))
        (hash-set! (lowerer-symbols up) text symbol)
        (set-module-strings! (lowerer-mod up)
                             (append (module-strings (lowerer-mod up))
                                     (list (string-lit symbol text))))
        symbol)))

(define (add-func! up f)
  (set-module-funcs! (lowerer-mod up)
                     (append (module-funcs (lowerer-mod up)) (list f))))

;; -- one function ------------------------------------------------------------

;; `breaks` is the stack of blocks a `break` jumps to, and `children?` says
;; whether anything is nested inside, which is what decides if the static link
;; can be dropped.
(define-class <fl> ()
  (up #:init-keyword #:up #:getter fl-up)
  (opts #:init-keyword #:opts #:getter fl-opts)
  (func #:init-keyword #:func #:getter fl-func)
  (cur #:init-keyword #:cur #:accessor fl-cur)
  (breaks #:init-value '() #:accessor fl-breaks)
  (counter #:init-value 0 #:accessor fl-counter)
  (children? #:init-value #f #:accessor fl-children?))

(define (new-fl up label name depth)
  (let* ((f (new-func label name depth))
         (me (make <fl> #:up up #:opts (lowerer-opts up) #:func f
                   #:cur (add-block! f "entry"))))
    (when (> depth 0) (set-func-link-slot! f (new-slot! f)))
    (add-func! up f)
    me))

;; -- block plumbing ----------------------------------------------------------

(define (fresh! me hint)
  (set! (fl-counter me) (+ 1 (fl-counter me)))
  (add-block! (fl-func me) (format #f "~a~a" hint (fl-counter me))))

(define (put! me i) (emit! (fl-cur me) i))

(define (terminate! me t)
  (put! me t)
  (set! (fl-cur me) (fresh! me "dead")))

(define (jump! me b) (terminate! me (i-jmp (block-label b))))

(define (branch! me cnd yes no)
  (terminate! me (i-cbr cnd (block-label yes) (block-label no) "")))

(define (reg! me) (new-reg! (fl-func me)))

(define (const! me value)
  (let ((r (reg! me)))
    (put! me (i-const r value))
    r))

;; -- function bodies ---------------------------------------------------------

(define (top-level! me decls)
  (lower-decls! me decls)
  (terminate! me (i-ret #f))
  (finish! me))

(define (function-body! me bind sym)
  (let ((f (fl-func me)))
    (when (> (func-depth f) 0)
      (let ((link (reg! me)))
        (set-func-params! f (append (func-params f) (list link)))
        (put! me (i-store-slot (func-link-slot f) link))))
    (let loop ((psyms (fun-sym-params sym)) (index (length (func-params f))))
      (unless (null? psyms)
        (let ((psym (car psyms)))
          (cond
           ;; The ninth argument and beyond is already in the frame when the
           ;; callee starts, at a negative slot, so it never takes a register.
           ((>= index ARGUMENT-REGISTERS)
            (set-var-sym-escapes?! psym #t)
            (set-var-sym-home! psym (in-frame (- (+ 1 (- index ARGUMENT-REGISTERS))))))
           (else
            (let ((r (reg! me)))
              (set-func-params! f (append (func-params f) (list r)))
              (cond
               ((var-sym-escapes? psym)
                (let ((slot (new-slot! f)))
                  (set-var-sym-home! psym (in-frame slot))
                  (put! me (i-store-slot slot r))))
               (else (set-var-sym-home! psym (in-register r))))))))
        (loop (cdr psyms) (+ index 1))))
    (let ((value (lower-exp (fun-bind-body bind) me)))
      (terminate! me (i-ret (and (not (eq? (fun-sym-result sym) 'unit)) value))))
    (finish! me)))

(define (finish! me)
  (drop-unreachable! (fl-func me))
  (drop-unused-link! me))

;; A function nobody nests inside, and that never looks outward, keeps no static
;; link: the slot goes, and every later slot moves down one.
(define (drop-unused-link! me)
  (let* ((f (fl-func me))
         (slot (func-link-slot f))
         (moved (lambda (s) (if (> s slot) (- s 1) s))))
    (unless (or (< slot 0)
                (fl-children? me)
                (any (lambda (b)
                       (any (lambda (i)
                              (and (is-a? i <i-load-slot>)
                                   (= (i-load-slot-slot i) slot)))
                            (instrs b)))
                     (walk f)))
      (for-each
       (lambda (b)
         (set-instrs!
          b
          (map (lambda (i)
                 (cond
                  ((is-a? i <i-store-slot>) (i-store-slot (moved (i-store-slot-slot i))
                                                          (i-store-slot-src i)))
                  ((is-a? i <i-load-slot>) (i-load-slot (instr-dst i)
                                                        (moved (i-load-slot-slot i))))
                  (else i)))
               (filter (lambda (i)
                         (not (and (is-a? i <i-store-slot>)
                                   (= (i-store-slot-slot i) slot))))
                       (instrs b)))))
       (walk f))
      (set-func-nslots! f (- (func-nslots f) 1))
      (set-func-link-slot! f -1))))

;; -- declarations ------------------------------------------------------------

(define-generic lower-decl!)

(define-method (lower-decl! (d <d-type>) me) *unspecified*)

(define-method (lower-decl! (d <d-val>) me)
  (let ((value (lower-exp (d-val-init d) me))
        (sym (d-val-sym d)))
    (when (and sym (not (eq? (var-sym-ty sym) 'unit)))
      (bind! me sym value))))

(define-method (lower-decl! (d <d-fun>) me)
  (set! (fl-children? me) #t)
  (for-each
   (lambda (b)
     (let ((sym (fun-bind-sym b)))
       (function-body!
        (new-fl (fl-up me) (fun-sym-label sym) (fun-sym-name sym) (fun-sym-depth sym))
        b sym)))
   (d-fun-binds d)))

(define (lower-decls! me decls)
  (for-each (lambda (d) (lower-decl! d me)) decls))

;; Give a variable its home, and put the initial value in it.
(define (bind! me sym value)
  (cond
   ((var-sym-escapes? sym)
    (let ((slot (new-slot! (fl-func me))))
      (set-var-sym-home! sym (in-frame slot))
      (put! me (i-store-slot slot value))))
   (else
    (let ((r (reg! me)))
      (set-var-sym-home! sym (in-register r))
      (put! me (i-move r value))))))

;; -- reaching variables and frames -------------------------------------------

(define (var-reg sym) (in-register-reg (var-sym-home sym)))
(define (var-slot sym) (in-frame-slot (var-sym-home sym)))

;; A register holding the frame pointer of the function at `depth`.
(define (frame-at me depth)
  (let* ((f (fl-func me))
         (r (reg! me)))
    (cond
     ((= depth (func-depth f)) (put! me (i-frame-addr r)) r)
     (else
      (put! me (i-load-slot r (func-link-slot f)))
      (let walk-out ((r r) (here (- (func-depth f) 1)))
        (cond
         ((<= here depth) r)
         (else
          (let ((next (reg! me)))
            (put! me (i-load next r (slot-offset 0)))
            (walk-out next (- here 1))))))))))

(define (read-var me sym)
  (cond
   ((not (var-sym-escapes? sym)) (var-reg sym))
   ((= (var-sym-depth sym) (func-depth (fl-func me)))
    (let ((r (reg! me)))
      (put! me (i-load-slot r (var-slot sym)))
      r))
   (else
    (let* ((base (frame-at me (var-sym-depth sym)))
           (r (reg! me)))
      (put! me (i-load r base (slot-offset (var-slot sym))))
      r))))

(define (write-var! me sym value)
  (cond
   ((not (var-sym-escapes? sym)) (put! me (i-move (var-reg sym) value)))
   ((= (var-sym-depth sym) (func-depth (fl-func me)))
    (put! me (i-store-slot (var-slot sym) value)))
   (else
    (let ((base (frame-at me (var-sym-depth sym))))
      (put! me (i-store base (slot-offset (var-slot sym)) value))))))

;; -- expressions -------------------------------------------------------------

(define-generic lower-exp)

(define (value me e)
  (or (lower-exp e me) (error "expected a value here")))

(define (binop! me op lhs rhs)
  (let ((r (reg! me)))
    (put! me (i-bin r op lhs rhs))
    r))

(define (compare! me op lhs rhs)
  (let ((r (reg! me)))
    (put! me (i-cmp r op lhs rhs))
    r))

(define (call-runtime! me name args)
  (let ((r (reg! me)))
    (put! me (i-call r name args))
    r))

(define-method (lower-exp (e <e-int>) me) (const! me (e-int-value e)))
(define-method (lower-exp (e <e-bool>) me) (const! me (if (e-bool-value e) 1 0)))
(define-method (lower-exp (e <e-nil>) me) (const! me 0))
(define-method (lower-exp (e <e-unit>) me) #f)

(define-method (lower-exp (e <e-str>) me)
  (let ((r (reg! me)))
    (put! me (i-str-const r (intern! (fl-up me) (e-str-value e))))
    r))

(define-method (lower-exp (e <e-var>) me) (read-var me (exp-sym e)))

(define-method (lower-exp (e <e-index>) me)
  (let ((addr (element-address me (e-index-array e) (e-index-index e)))
        (r (reg! me)))
    (put! me (i-load r addr WORD))
    r))

(define-method (lower-exp (e <e-neg>) me)
  (binop! me "-" (const! me 0) (value me (e-neg-operand e))))

(define-method (lower-exp (e <e-break>) me)
  (terminate! me (i-jmp (car (fl-breaks me))))
  #f)

(define-method (lower-exp (e <e-seq>) me)
  (let loop ((items (e-seq-items e)) (last #f))
    (if (null? items) last (loop (cdr items) (lower-exp (car items) me)))))

(define-method (lower-exp (e <e-let>) me)
  (lower-decls! me (e-let-decls e))
  (lower-exp (e-let-body e) me))

(define-method (lower-exp (e <e-assign>) me)
  (assign! me (e-assign-target e) (e-assign-value e))
  #f)

(define-method (lower-exp (e <e-while>) me)
  (while-exp! me (e-while-test e) (e-while-body e))
  #f)

(define-method (lower-exp (e <e-for>) me)
  (for-exp! me e (e-for-lo e) (e-for-hi e) (e-for-body e))
  #f)

(define-method (lower-exp (e <e-bin>) me)
  (let* ((op (binary-op e))
         (lhs-exp (binary-lhs e))
         (rhs-exp (binary-rhs e))
         (lhs (value me lhs-exp))
         (rhs (value me rhs-exp)))
    (cond
     ((string=? op "^") (call-runtime! me "wol_concat" (list lhs rhs)))
     ((member op '("/" "mod"))
      (check-nonzero! me rhs)
      (cond
       ((string=? op "/") (binop! me "/" lhs rhs))
       (else
        ;; The remainder is spelled out rather than left to the emitter: the
        ;; quotient it needs in between is a value like any other, and the
        ;; allocator can find it a register.  The emitter fuses the last two
        ;; back into one `msub`.
        (let* ((quotient (binop! me "/" lhs rhs))
               (product (binop! me "*" quotient rhs)))
          (binop! me "-" lhs product)))))
     ((member op '("+" "-" "*")) (binop! me op lhs rhs))
     ((eq? (exp-ty lhs-exp) 'string)
      (let ((order (call-runtime! me "wol_string_cmp" (list lhs rhs))))
        (compare! me op order (const! me 0))))
     (else (compare! me op lhs rhs)))))

;; `andalso` and `orelse` are branches, so the result needs a register.
(define-method (lower-exp (e <e-logic>) me)
  (let* ((op (binary-op e))
         (result (reg! me))
         (rhs-block (fresh! me "logic"))
         (join (fresh! me "logicjoin"))
         (lhs (value me (binary-lhs e))))
    (put! me (i-move result lhs))
    (if (string=? op "andalso")
        (branch! me lhs rhs-block join)
        (branch! me lhs join rhs-block))
    (set! (fl-cur me) rhs-block)
    (put! me (i-move result (value me (binary-rhs e))))
    (jump! me join)
    (set! (fl-cur me) join)
    result))

(define-method (lower-exp (e <e-call>) me)
  (let ((sym (exp-sym e))
        (args (e-call-args e)))
    (let ((builtin (fun-sym-builtin sym)))
      (cond
       ((equal? builtin "not")
        (binop! me "xor" (value me (first args)) (const! me 1)))
       ((equal? builtin "array")
        (let* ((count (value me (first args)))
               (init (value me (second args))))
          (call-runtime! me "wol_array" (list count init))))
       ((equal? builtin "length")
        (let ((arr (value me (first args))))
          (check-not-nil! me arr)
          (let ((r (reg! me)))
            (put! me (i-load r arr 0))
            r)))
       (else
        (let* ((lowered (map-in-order (lambda (a) (value me a)) args))
               (full (if builtin
                         lowered
                         (cons (frame-at me (- (fun-sym-depth sym) 1)) lowered))))
          (cond
           ((eq? (fun-sym-result sym) 'unit)
            (put! me (i-call #f (fun-sym-label sym) full))
            #f)
           (else (call-runtime! me (fun-sym-label sym) full)))))))))

(define-method (lower-exp (e <e-record>) me)
  (let* ((rec (exp-ty e))
         (size (const! me (* WORD (max (length (ty-record-fields rec)) 1))))
         (base (call-runtime! me "wol_alloc" (list size))))
    (let loop ((inits (e-record-inits e)) (i 0))
      (unless (null? inits)
        (put! me (i-store base (* WORD i) (value me (field-init-value (car inits)))))
        (loop (cdr inits) (+ i 1))))
    base))

(define-method (lower-exp (e <e-field>) me)
  (let ((base (value me (e-field-record e))))
    (check-not-nil! me base)
    (let ((r (reg! me)))
      (put! me (i-load r base (* WORD (exp-offset e))))
      r)))

(define-method (lower-exp (e <e-if>) me)
  (let* ((result (and (not (eq? (exp-ty e) 'unit)) (reg! me)))
         (yes (fresh! me "then"))
         (no (fresh! me "else"))
         (join (fresh! me "join")))
    (define (copy-into branch)
      (let ((value (lower-exp branch me)))
        (when (and result value) (put! me (i-move result value)))))
    (branch! me (value me (e-if-test e)) yes no)

    (set! (fl-cur me) yes)
    (copy-into (e-if-then e))
    (jump! me join)

    (set! (fl-cur me) no)
    (when (e-if-else e) (copy-into (e-if-else e)))
    (jump! me join)

    (set! (fl-cur me) join)
    result))

;; The address of `a[i]`, without the length word the elements follow.
;;
;; The selector turns this into one `add` with a shifted operand, and the word
;; is the load's displacement, so the two instructions that come out are the two
;; the machine has.
(define (element-address me array index)
  (let* ((base (value me array))
         (idx (value me index)))
    (check-not-nil! me base)
    (check-bounds! me base idx)
    (binop! me "+" base (binop! me "shl" idx (const! me 3)))))

(define-generic assign-to!)

(define-method (assign-to! (target <e-var>) me v)
  (write-var! me (exp-sym target) (value me v)))

(define-method (assign-to! (target <e-index>) me v)
  (let ((addr (element-address me (e-index-array target) (e-index-index target))))
    (put! me (i-store addr WORD (value me v)))))

(define-method (assign-to! (target <e-field>) me v)
  (let ((base (value me (e-field-record target))))
    (check-not-nil! me base)
    (put! me (i-store base (* WORD (exp-offset target)) (value me v)))))

(define (assign! me target v) (assign-to! target me v))

(define (in-loop! me done thunk)
  (set! (fl-breaks me) (cons (block-label done) (fl-breaks me)))
  (thunk)
  (set! (fl-breaks me) (cdr (fl-breaks me))))

(define (while-exp! me cnd body-exp)
  (let ((test (fresh! me "test"))
        (body (fresh! me "body"))
        (done (fresh! me "done")))
    (jump! me test)
    (set! (fl-cur me) test)
    (branch! me (value me cnd) body done)
    (set! (fl-cur me) body)
    (in-loop! me done (lambda () (lower-exp body-exp me)))
    (jump! me test)
    (set! (fl-cur me) done)))

;; `for i = lo to hi` counts up, and stops before overflowing at `hi`.
(define (for-exp! me e lo-exp hi-exp body-exp)
  (let* ((sym (exp-sym e))
         (lo (value me lo-exp))
         (hi-value (value me hi-exp))
         (hi (reg! me)))
    (put! me (i-move hi hi-value))
    (bind! me sym lo)
    (let ((body (fresh! me "forbody"))
          (step (fresh! me "forstep"))
          (done (fresh! me "fordone")))
      (branch! me (compare! me "<=" lo hi) body done)

      (set! (fl-cur me) body)
      (in-loop! me done (lambda () (lower-exp body-exp me)))
      (branch! me (compare! me "<" (read-var me sym) hi) step done)

      (set! (fl-cur me) step)
      (write-var! me sym (binop! me "+" (read-var me sym) (const! me 1)))
      (jump! me body)

      (set! (fl-cur me) done))))

;; -- run-time checks ---------------------------------------------------------

;; Each of the three is the same shape: a branch to a block that calls the
;; runtime and never comes back, and a block where the program carries on.
(define (guard! me hint test-reg bad-first? call)
  (let ((bad (fresh! me hint))
        (ok (fresh! me "ok")))
    (if bad-first? (branch! me test-reg bad ok) (branch! me test-reg ok bad))
    (set! (fl-cur me) bad)
    (put! me call)
    (jump! me ok)
    (set! (fl-cur me) ok)))

(define (check-not-nil! me base)
  (when (options-checks? (fl-opts me))
    (guard! me "nil" (compare! me "=" base (const! me 0)) #t
            (i-call #f "wol_nil_error" '()))))

(define (check-bounds! me base idx)
  (when (options-checks? (fl-opts me))
    (let ((len (reg! me)))
      (put! me (i-load len base 0))
      (guard! me "oob" (compare! me "u<" idx len) #f
              (i-call #f "wol_bounds_error" (list idx len))))))

(define (check-nonzero! me rhs)
  (when (options-checks? (fl-opts me))
    (guard! me "divzero" (compare! me "=" rhs (const! me 0)) #t
            (i-call #f "wol_div_error" '()))))

;; -- the whole program -------------------------------------------------------

(define* (lower prog #:optional (opts (options #t)))
  (let ((up (make <lowerer> #:opts opts #:mod (new-module))))
    (top-level! (new-fl up "wol_main" "main" 0) prog)
    (lowerer-mod up)))

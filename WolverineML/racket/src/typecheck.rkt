#lang racket/base

;; The type checker, which also decides which variables escape.
;;
;; Types are monomorphic and there is nothing to infer but the type of a `val`.
;; A `fun` without a result type is a procedure and returns `unit`, which is what
;; makes recursion checkable without inference: every function's signature is
;; known before any body is.
;;
;; The pass has a second job.  A variable read from inside a function nested more
;; deeply than the one that binds it cannot live in a register, because the inner
;; function reaches it through a static link at run time.  Every lookup that
;; crosses a function boundary marks the variable as escaping, and the lowering
;; pass gives those a frame slot instead.

(require racket/list
         racket/string
         "diag.rkt"
         "types.rkt"
         (prefix-in ast: "ast.rkt"))

(provide check)

(define builtins
  ;; name, argument types, result, the symbol the runtime calls it
  '(("print" (string) unit "wol_print")
    ("println" (string) unit "wol_println")
    ("printInt" (int) unit "wol_print_int")
    ("flush" () unit "wol_flush")
    ("getChar" () string "wol_getchar")
    ("ord" (string) int "wol_ord")
    ("chr" (int) string "wol_chr")
    ("size" (string) int "wol_size")
    ("substring" (string int int) string "wol_substring")
    ("concat" (string string) string "wol_concat")
    ("intToString" (int) string "wol_int_to_string")
    ("stringToInt" (string) int "wol_string_to_int")
    ("exit" (int) unit "wol_exit")))

;; The three whose types depend on their arguments, so the checker types them.
(define specials '("array" "length" "not"))

(define arithmetic '("+" "-" "*" "/" "mod"))
(define ordering '("<" "<=" ">" ">="))
(define equality '("=" "<>"))

;; A scope is two tables; the stack of them is innermost first, so a lookup walks
;; outward and stops at the first hit.
(struct scope (tys vals) #:transparent)
(define (new-scope) (scope (make-hash) (make-hash)))

(struct checker ([scopes #:mutable] [depth #:mutable] [loops #:mutable] labels))

(define (prelude)
  (define s (new-scope))
  (for ([t '(int string bool unit)]) (hash-set! (scope-tys s) (symbol->string t) t))
  (for ([b (in-list builtins)])
    (define params
      (for/list ([t (in-list (second b))] [i (in-naturals)])
        (var-sym (format "a~a" i) t #f 0 #f #f)))
    (hash-set! (scope-vals s) (first b)
               (fun-sym (first b) (fourth b) params (third b) 0 (fourth b))))
  (for ([name (in-list specials)])
    (hash-set! (scope-vals s) name (fun-sym name name '() 'unit 0 name)))
  s)

;; -- scopes ------------------------------------------------------------------

(define (push! c) (set-checker-scopes! c (cons (new-scope) (checker-scopes c))))
(define (pop! c) (set-checker-scopes! c (cdr (checker-scopes c))))

(define (bind-val! c name sym) (hash-set! (scope-vals (car (checker-scopes c))) name sym))
(define (bind-type! c name ty) (hash-set! (scope-tys (car (checker-scopes c))) name ty))

(define (lookup c pick name at what)
  (or (for/or ([s (in-list (checker-scopes c))]) (hash-ref (pick s) name #f))
      (type-error at "`~a` is not ~a" name what)))

(define (lookup-val c name at) (lookup c scope-vals name at "bound"))
(define (lookup-type c name at) (lookup c scope-tys name at "a type"))

;; Two functions of the same name in one program need two labels.
(define (unique-label c name)
  (define n (hash-ref (checker-labels c) name 0))
  (hash-set! (checker-labels c) name (add1 n))
  (if (zero? n) (format "wol_~a" name) (format "wol_~a.~a" name n)))

(define (unify want got at where)
  (unless (compatible? want got)
    (type-error at "expected `~a`, found `~a` ~a" (show-ty want) (show-ty got) where)))

;; -- types as they are written -----------------------------------------------

(define (resolve c t)
  (cond
    [(ast:t:name? t) (lookup-type c (ast:t:name-name t) (ast:t:name-at t))]
    [(ast:t:array? t) (ty:array (resolve c (ast:t:array-elem t)))]
    [else (type-error (ast:t:record-at t)
                      "a record type has to be given a name by `type`")]))

;; -- declarations ------------------------------------------------------------

(define (decls c list) (for ([d (in-list list)]) (decl c d)))

(define (decl c d)
  (cond
    [(ast:d:type? d) (type-decl c (ast:d:type-binds d))]
    [(ast:d:val? d) (val-decl c d)]
    [else (fun-decl c (ast:d:fun-binds d))]))

;; Records are bound before any field is resolved, so a group of `type`s may name
;; each other and itself.
(define (type-decl c binds)
  (define records
    (for/list ([b (in-list binds)] #:when (ast:t:record? (ast:type-bind-bound b)))
      (define r (ty:record (ast:type-bind-name b) '()))
      (bind-type! c (ast:type-bind-name b) r)
      (cons r (ast:t:record-fields (ast:type-bind-bound b)))))
  (for ([b (in-list binds)] #:unless (ast:t:record? (ast:type-bind-bound b)))
    (bind-type! c (ast:type-bind-name b) (resolve c (ast:type-bind-bound b))))
  (for ([pair (in-list records)])
    (define seen (make-hash))
    (set-ty:record-fields!
     (car pair)
     (for/list ([f (in-list (cdr pair))])
       (when (hash-ref seen (ast:ty-field-name f) #f)
         (type-error (ast:ty-field-at f) "duplicate field `~a`" (ast:ty-field-name f)))
       (hash-set! seen (ast:ty-field-name f) #t)
       (cons (ast:ty-field-name f) (resolve c (ast:ty-field-ty f)))))))

(define (val-decl c d)
  (define got0 (infer-exp c (ast:d:val-init d)))
  (define got
    (cond
      [(ast:d:val-written d)
       => (λ (written)
            (define want (resolve c written))
            (unify want got0 (ast:exp-at (ast:d:val-init d)) "in this binding")
            want)]
      [else got0]))
  (cond
    [(not (ast:d:val-name d))
     (unify 'unit got (ast:exp-at (ast:d:val-init d)) "in `val () =`")]
    [else
     (when (eq? got 'nil)
       (type-error (ast:d:val-at d) "`~a` needs a type annotation to hold `nil`"
                   (ast:d:val-name d)))
     (define sym (var-sym (ast:d:val-name d) got (ast:d:val-var? d) (checker-depth c) #f #f))
     (ast:set-d:val-sym! d sym)
     (bind-val! c (ast:d:val-name d) sym)]))

;; Every signature in the group is bound before any body is typed.
(define (fun-decl c binds)
  (for ([b (in-list binds)])
    (define seen (make-hash))
    (define params
      (for/list ([p (in-list (ast:fun-bind-params b))])
        (when (hash-ref seen (ast:param-name p) #f)
          (type-error (ast:param-at p) "duplicate parameter `~a`" (ast:param-name p)))
        (hash-set! seen (ast:param-name p) #t)
        (define sym (var-sym (ast:param-name p) (resolve c (ast:param-ty p)) #f
                             (add1 (checker-depth c)) #f #f))
        (ast:set-param-sym! p sym)
        sym))
    (define result
      (if (ast:fun-bind-result b) (resolve c (ast:fun-bind-result b)) 'unit))
    (define sym (fun-sym (ast:fun-bind-label b) (unique-label c (ast:fun-bind-label b))
                         params result (add1 (checker-depth c)) #f))
    (ast:set-fun-bind-sym! b sym)
    (bind-val! c (ast:fun-bind-label b) sym))
  (for ([b (in-list binds)])
    (define signature (ast:fun-bind-sym b))
    (set-checker-depth! c (add1 (checker-depth c)))
    (define outer (checker-loops c))
    (set-checker-loops! c 0)
    (push! c)
    (for ([p (in-list (ast:fun-bind-params b))])
      (bind-val! c (ast:param-name p) (ast:param-sym p)))
    (define got (infer-exp c (ast:fun-bind-body b)))
    (unify (fun-sym-result signature) got (ast:exp-at (ast:fun-bind-body b))
           (format "in the body of `~a`" (ast:fun-bind-label b)))
    (pop! c)
    (set-checker-loops! c outer)
    (set-checker-depth! c (sub1 (checker-depth c)))))

;; -- expressions -------------------------------------------------------------

(define (infer-exp c e)
  (define ty (infer c e))
  (ast:set-exp-ty! e ty)
  ty)

(define (infer c e)
  (define n (ast:exp-node e))
  (define at (ast:exp-at e))
  (cond
    [(ast:e:int? n) 'int]
    [(ast:e:str? n) 'string]
    [(ast:e:bool? n) 'bool]
    [(ast:e:nil? n) 'nil]
    [(ast:e:unit? n) 'unit]
    [(ast:e:var? n) (variable c e n)]
    [(ast:e:call? n) (call-exp c e n)]
    [(ast:e:record? n) (record-lit c e n)]
    [(ast:e:index? n) (index-exp c e n)]
    [(ast:e:field? n) (field-exp c e n)]
    [(ast:e:neg? n)
     (unify 'int (infer-exp c (ast:e:neg-operand n)) at "in a negation")
     'int]
    [(ast:e:bin? n) (binop c e n)]
    [(ast:e:logic? n)
     (define op (ast:e:logic-op n))
     (unify 'bool (infer-exp c (ast:e:logic-lhs n)) (ast:exp-at (ast:e:logic-lhs n))
            (format "on the left of `~a`" op))
     (unify 'bool (infer-exp c (ast:e:logic-rhs n)) (ast:exp-at (ast:e:logic-rhs n))
            (format "on the right of `~a`" op))
     'bool]
    [(ast:e:assign? n) (assign c e n)]
    [(ast:e:if? n) (if-exp c e n)]
    [(ast:e:while? n)
     (unify 'bool (infer-exp c (ast:e:while-cond n)) (ast:exp-at (ast:e:while-cond n))
            "as a `while` condition")
     (set-checker-loops! c (add1 (checker-loops c)))
     (unify 'unit (infer-exp c (ast:e:while-body n)) (ast:exp-at (ast:e:while-body n))
            "in a `while` body")
     (set-checker-loops! c (sub1 (checker-loops c)))
     'unit]
    [(ast:e:for? n) (for-exp c e n)]
    [(ast:e:break? n)
     (when (zero? (checker-loops c)) (type-error at "`break` is outside any loop"))
     'unit]
    [(ast:e:seq? n)
     (for/fold ([ty 'unit]) ([item (in-list (ast:e:seq-items n))]) (infer-exp c item))]
    [else
     (push! c)
     (decls c (ast:e:let-decls n))
     (define ty (infer-exp c (ast:e:let-body n)))
     (pop! c)
     ty]))

(define (variable c e n)
  (define sym (lookup-val c (ast:e:var-name n) (ast:exp-at e)))
  (when (fun-sym? sym)
    (type-error (ast:exp-at e) "`~a` is a function, and functions are not values"
                (ast:e:var-name n)))
  ;; Read from deeper than it was bound: it cannot live in a register.
  (when (< (var-sym-depth sym) (checker-depth c)) (set-var-sym-escapes?! sym #t))
  (ast:set-exp-sym! e sym)
  (var-sym-ty sym))

(define (arity e callee args want)
  (unless (= (length args) want)
    (type-error (ast:exp-at e) "`~a` takes ~a argument~a, given ~a"
                callee want (if (= want 1) "" "s") (length args))))

(define (call-exp c e n)
  (define callee (ast:e:call-callee n))
  (define args (ast:e:call-args n))
  (define f (lookup-val c callee (ast:exp-at e)))
  (when (var-sym? f)
    (type-error (ast:exp-at e) "`~a` is a variable, not a function" callee))
  (ast:set-exp-sym! e f)
  (case (fun-sym-builtin f)
    [("array")
     (arity e callee args 2)
     (unify 'int (infer-exp c (first args)) (ast:exp-at (first args)) "as an array length")
     (define elem (infer-exp c (second args)))
     (when (eq? elem 'nil)
       (type-error (ast:exp-at (second args))
                   "`array` cannot tell which record `nil` stands for"))
     (ty:array elem)]
    [("length")
     (arity e callee args 1)
     (define got (infer-exp c (first args)))
     (unless (ty:array? got)
       (type-error (ast:exp-at (first args)) "`length` wants an array, found `~a`"
                   (show-ty got)))
     'int]
    [("not")
     (arity e callee args 1)
     (unify 'bool (infer-exp c (first args)) (ast:exp-at e) "in a call to `not`")
     'bool]
    [else
     (arity e callee args (length (fun-sym-params f)))
     (for ([a (in-list args)] [p (in-list (fun-sym-params f))])
       (unify (var-sym-ty p) (infer-exp c a) (ast:exp-at a)
              (format "in a call to `~a`" callee)))
     (fun-sym-result f)]))

;; The initialisers are put into declaration order, which is what lowering wants.
(define (record-lit c e n)
  (define found (lookup-type c (ast:e:record-tyname n) (ast:exp-at e)))
  (unless (ty:record? found)
    (type-error (ast:exp-at e) "`~a` is not a record type" (ast:e:record-tyname n)))
  (define seen (make-hash))
  (for ([f (in-list (ast:e:record-inits n))])
    (when (hash-ref seen (ast:field-init-name f) #f)
      (type-error (ast:field-init-at f) "field `~a` is given twice"
                  (ast:field-init-name f)))
    (when (< (record-index found (ast:field-init-name f)) 0)
      (type-error (ast:field-init-at f) "`~a` has no field `~a`"
                  (ty:record-name found) (ast:field-init-name f)))
    (hash-set! seen (ast:field-init-name f) f))
  (ast:set-e:record-inits!
   n
   (for/list ([want (in-list (ty:record-fields found))])
     (define init (hash-ref seen (car want) #f))
     (unless init (type-error (ast:exp-at e) "field `~a` is missing" (car want)))
     (unify (cdr want) (infer-exp c (ast:field-init-value init))
            (ast:field-init-at init) (format "in field `~a`" (car want)))
     init))
  found)

(define (index-exp c e n)
  (define got (infer-exp c (ast:e:index-array n)))
  (unless (ty:array? got)
    (type-error (ast:exp-at e) "`~a` is not an array" (show-ty got)))
  (unify 'int (infer-exp c (ast:e:index-index n)) (ast:exp-at (ast:e:index-index n))
         "as an array index")
  (ty:array-elem got))

(define (field-exp c e n)
  (define got (infer-exp c (ast:e:field-record n)))
  (unless (ty:record? got)
    (type-error (ast:exp-at e) "`~a` is not a record" (show-ty got)))
  (define ty (record-field-type got (ast:e:field-select n)))
  (unless ty
    (type-error (ast:exp-at e) "`~a` has no field `~a`"
                (ty:record-name got) (ast:e:field-select n)))
  (ast:set-exp-offset! e (record-index got (ast:e:field-select n)))
  ty)

(define (binop c e n)
  (define op (ast:e:bin-op n))
  (define lhs (ast:e:bin-lhs n))
  (define rhs (ast:e:bin-rhs n))
  (define l (infer-exp c lhs))
  (define r (infer-exp c rhs))
  (cond
    [(member op arithmetic)
     (unify 'int l (ast:exp-at lhs) (format "on the left of `~a`" op))
     (unify 'int r (ast:exp-at rhs) (format "on the right of `~a`" op))
     'int]
    [(string=? op "^")
     (unify 'string l (ast:exp-at lhs) "on the left of `^`")
     (unify 'string r (ast:exp-at rhs) "on the right of `^`")
     'string]
    [(member op ordering)
     (unless (memq l '(int string))
       (type-error (ast:exp-at e) "`~a` compares int or string, not `~a`" op (show-ty l)))
     (unify l r (ast:exp-at rhs) (format "on the right of `~a`" op))
     'bool]
    [(member op equality)
     (when (or (eq? l 'unit) (eq? r 'unit))
       (type-error (ast:exp-at e) "`~a` cannot compare `unit`" op))
     (unless (compatible? l r)
       (type-error (ast:exp-at e) "`~a` compares `~a` with `~a`" op (show-ty l) (show-ty r)))
     'bool]
    [else (type-error (ast:exp-at e) "unknown operator `~a`" op)]))

(define (assign c e n)
  (define target (ast:e:assign-target n))
  (define ty (infer-exp c target))
  (when (ast:e:var? (ast:exp-node target))
    (define sym (ast:exp-sym target))
    (unless (var-sym-mutable? sym)
      (type-error (ast:exp-at e) "`~a` is a `val`, so it cannot be assigned"
                  (var-sym-name sym))))
  (unify ty (infer-exp c (ast:e:assign-value n)) (ast:exp-at (ast:e:assign-value n))
         "in an assignment")
  'unit)

(define (if-exp c e n)
  (define cnd (ast:e:if-cond n))
  (define then (ast:e:if-then n))
  (define els (ast:e:if-els n))
  (unify 'bool (infer-exp c cnd) (ast:exp-at cnd) "as an `if` condition")
  (define t (infer-exp c then))
  (cond
    [(not els) (unify 'unit t (ast:exp-at then) "in an `if` with no `else`") 'unit]
    [else
     (define other (infer-exp c els))
     (unless (compatible? t other)
       (type-error (ast:exp-at e) "the branches differ: `~a` and `~a`"
                   (show-ty t) (show-ty other)))
     (if (eq? t 'nil) other t)]))

(define (for-exp c e n)
  (define lo (ast:e:for-lo n))
  (define hi (ast:e:for-hi n))
  (unify 'int (infer-exp c lo) (ast:exp-at lo) "as a `for` bound")
  (unify 'int (infer-exp c hi) (ast:exp-at hi) "as a `for` bound")
  (define sym (var-sym (ast:e:for-binder n) 'int #f (checker-depth c) #f #f))
  (ast:set-exp-sym! e sym)
  (push! c)
  (bind-val! c (ast:e:for-binder n) sym)
  (set-checker-loops! c (add1 (checker-loops c)))
  (unify 'unit (infer-exp c (ast:e:for-body n)) (ast:exp-at (ast:e:for-body n))
         "in a `for` body")
  (set-checker-loops! c (sub1 (checker-loops c)))
  (pop! c)
  'unit)

;; Types the program in place: every node comes back with its type.
(define (check prog)
  (define c (checker (list (prelude)) 0 0 (make-hash)))
  (push! c)
  (decls c prog)
  (pop! c))

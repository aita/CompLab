;;; The type checker, which also decides which variables escape.
;;;
;;; Types are monomorphic and there is nothing to infer but the type of a `val`.
;;; A `fun` without a result type is a procedure and returns `unit`, which is
;;; what makes recursion checkable without inference: every function's signature
;;; is known before any body is.
;;;
;;; The pass has a second job.  A variable read from inside a function nested
;;; more deeply than the one that binds it cannot live in a register, because
;;; the inner function reaches it through a static link at run time.  Every
;;; lookup that crosses a function boundary marks the variable as escaping, and
;;; the lowering pass gives those a frame slot instead.
;;;
;;; `infer` is one generic function with a method per node class, so the
;;; question "what type is this?" is asked of the node and answered by the node.

(define-module (wolv typecheck)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (first second third fourth any every))
  #:use-module (ice-9 format)
  #:use-module (wolv diag)
  #:use-module (wolv types)
  #:use-module (wolv ast)
  #:export (check))

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

;; A scope is two tables; the stack of them is innermost first, so a lookup
;; walks outward and stops at the first hit.
(define-class <scope> ()
  (tys #:init-thunk make-hash-table #:getter scope-tys)
  (vals #:init-thunk make-hash-table #:getter scope-vals))

(define-class <checker> ()
  (scopes #:init-value '() #:accessor checker-scopes)
  (depth #:init-value 0 #:accessor checker-depth)
  (loops #:init-value 0 #:accessor checker-loops)
  (labels #:init-thunk make-hash-table #:getter checker-labels))

(define (prelude)
  (let ((s (make <scope>)))
    (for-each (lambda (t) (hash-set! (scope-tys s) (symbol->string t) t))
              '(int string bool unit))
    (for-each
     (lambda (b)
       (let ((params (map (lambda (t i) (var-sym (format #f "a~a" i) t #f 0))
                          (second b)
                          (iota (length (second b))))))
         (hash-set! (scope-vals s) (first b)
                    (fun-sym (first b) (fourth b) params (third b) 0 (fourth b)))))
     builtins)
    (for-each (lambda (name)
                (hash-set! (scope-vals s) name (fun-sym name name '() 'unit 0 name)))
              specials)
    s))

;; -- scopes ------------------------------------------------------------------

(define (push! c) (set! (checker-scopes c) (cons (make <scope>) (checker-scopes c))))
(define (pop! c) (set! (checker-scopes c) (cdr (checker-scopes c))))

(define (bind-val! c name sym)
  (hash-set! (scope-vals (car (checker-scopes c))) name sym))
(define (bind-type! c name ty)
  (hash-set! (scope-tys (car (checker-scopes c))) name ty))

(define (lookup c pick name at what)
  (or (any (lambda (s) (hash-ref (pick s) name #f)) (checker-scopes c))
      (type-error at "`~a` is not ~a" name what)))

(define (lookup-val c name at) (lookup c scope-vals name at "bound"))
(define (lookup-type c name at) (lookup c scope-tys name at "a type"))

;; Two functions of the same name in one program need two labels.
(define (unique-label c name)
  (let ((n (hash-ref (checker-labels c) name 0)))
    (hash-set! (checker-labels c) name (+ n 1))
    (if (zero? n) (format #f "wol_~a" name) (format #f "wol_~a.~a" name n))))

(define (unify want got at where)
  (unless (compatible? want got)
    (type-error at "expected `~a`, found `~a` ~a" (show-ty want) (show-ty got) where)))

;; -- types as they are written -----------------------------------------------

(define-generic resolve)

(define-method (resolve (t <t-name>) c) (lookup-type c (t-name-name t) (node-at t)))
(define-method (resolve (t <t-array>) c) (ty-array (resolve (t-array-elem t) c)))
(define-method (resolve (t <t-record>) c)
  (type-error (node-at t) "a record type has to be given a name by `type`"))

;; -- declarations ------------------------------------------------------------

(define-generic declare)

;; Records are bound before any field is resolved, so a group of `type`s may
;; name each other and itself.
(define-method (declare (d <d-type>) c)
  (let ((binds (d-type-binds d)))
    (let ((records
           (let loop ((bs binds) (acc '()))
             (cond
              ((null? bs) (reverse acc))
              ((is-a? (type-bind-bound (car bs)) <t-record>)
               (let ((r (ty-record (type-bind-name (car bs)) '())))
                 (bind-type! c (type-bind-name (car bs)) r)
                 (loop (cdr bs)
                       (cons (cons r (t-record-fields (type-bind-bound (car bs)))) acc))))
              (else (loop (cdr bs) acc))))))
      (for-each (lambda (b)
                  (unless (is-a? (type-bind-bound b) <t-record>)
                    (bind-type! c (type-bind-name b) (resolve (type-bind-bound b) c))))
                binds)
      (for-each
       (lambda (pair)
         (let ((seen (make-hash-table)))
           (set-ty-record-fields!
            (car pair)
            (map (lambda (f)
                   (when (hash-ref seen (ty-field-name f) #f)
                     (type-error (ty-field-at f) "duplicate field `~a`" (ty-field-name f)))
                   (hash-set! seen (ty-field-name f) #t)
                   (cons (ty-field-name f) (resolve (ty-field-ty f) c)))
                 (cdr pair)))))
       records))))

(define-method (declare (d <d-val>) c)
  (let* ((got0 (infer-exp (d-val-init d) c))
         (written (d-val-written d))
         (got (cond
               (written
                (let ((want (resolve written c)))
                  (unify want got0 (node-at (d-val-init d)) "in this binding")
                  want))
               (else got0))))
    (cond
     ((not (d-val-name d))
      (unify 'unit got (node-at (d-val-init d)) "in `val () =`"))
     (else
      (when (eq? got 'nil)
        (type-error (node-at d) "`~a` needs a type annotation to hold `nil`"
                    (d-val-name d)))
      (let ((sym (var-sym (d-val-name d) got (d-val-var? d) (checker-depth c))))
        (set-d-val-sym! d sym)
        (bind-val! c (d-val-name d) sym))))))

;; Every signature in the group is bound before any body is typed.
(define-method (declare (d <d-fun>) c)
  (let ((binds (d-fun-binds d)))
    (for-each
     (lambda (b)
       (let ((seen (make-hash-table)))
         (let ((params
                (map (lambda (p)
                       (when (hash-ref seen (param-name p) #f)
                         (type-error (param-at p) "duplicate parameter `~a`" (param-name p)))
                       (hash-set! seen (param-name p) #t)
                       (let ((sym (var-sym (param-name p) (resolve (param-ty p) c) #f
                                           (+ 1 (checker-depth c)))))
                         (set-param-sym! p sym)
                         sym))
                     (fun-bind-params b))))
           (let* ((result (if (fun-bind-result b) (resolve (fun-bind-result b) c) 'unit))
                  (sym (fun-sym (fun-bind-label b) (unique-label c (fun-bind-label b))
                                params result (+ 1 (checker-depth c)) #f)))
             (set-fun-bind-sym! b sym)
             (bind-val! c (fun-bind-label b) sym)))))
     binds)
    (for-each
     (lambda (b)
       (let ((signature (fun-bind-sym b))
             (outer (checker-loops c)))
         (set! (checker-depth c) (+ 1 (checker-depth c)))
         (set! (checker-loops c) 0)
         (push! c)
         (for-each (lambda (p) (bind-val! c (param-name p) (param-sym p)))
                   (fun-bind-params b))
         (let ((got (infer-exp (fun-bind-body b) c)))
           (unify (fun-sym-result signature) got (node-at (fun-bind-body b))
                  (format #f "in the body of `~a`" (fun-bind-label b))))
         (pop! c)
         (set! (checker-loops c) outer)
         (set! (checker-depth c) (- (checker-depth c) 1))))
     binds)))

;; -- expressions -------------------------------------------------------------

(define (infer-exp e c)
  (let ((ty (infer e c)))
    (set-exp-ty! e ty)
    ty))

(define-generic infer)

(define-method (infer (e <e-int>) c) 'int)
(define-method (infer (e <e-str>) c) 'string)
(define-method (infer (e <e-bool>) c) 'bool)
(define-method (infer (e <e-nil>) c) 'nil)
(define-method (infer (e <e-unit>) c) 'unit)

(define-method (infer (e <e-var>) c)
  (let ((sym (lookup-val c (e-var-name e) (node-at e))))
    (when (is-a? sym <fun-sym>)
      (type-error (node-at e) "`~a` is a function, and functions are not values"
                  (e-var-name e)))
    ;; Read from deeper than it was bound: it cannot live in a register.
    (when (< (var-sym-depth sym) (checker-depth c))
      (set-var-sym-escapes?! sym #t))
    (set-exp-sym! e sym)
    (var-sym-ty sym)))

(define (arity e callee args want)
  (unless (= (length args) want)
    (type-error (node-at e) "`~a` takes ~a argument~a, given ~a"
                callee want (if (= want 1) "" "s") (length args))))

(define-method (infer (e <e-call>) c)
  (let ((callee (e-call-callee e))
        (args (e-call-args e))
        (f (lookup-val c (e-call-callee e) (node-at e))))
    (when (is-a? f <var-sym>)
      (type-error (node-at e) "`~a` is a variable, not a function" callee))
    (set-exp-sym! e f)
    (let ((builtin (fun-sym-builtin f)))
      (cond
       ((equal? builtin "array")
        (arity e callee args 2)
        (unify 'int (infer-exp (first args) c) (node-at (first args)) "as an array length")
        (let ((elem (infer-exp (second args) c)))
          (when (eq? elem 'nil)
            (type-error (node-at (second args))
                        "`array` cannot tell which record `nil` stands for"))
          (ty-array elem)))
       ((equal? builtin "length")
        (arity e callee args 1)
        (let ((got (infer-exp (first args) c)))
          (unless (is-a? got <ty-array>)
            (type-error (node-at (first args)) "`length` wants an array, found `~a`"
                        (show-ty got)))
          'int))
       ((equal? builtin "not")
        (arity e callee args 1)
        (unify 'bool (infer-exp (first args) c) (node-at e) "in a call to `not`")
        'bool)
       (else
        (arity e callee args (length (fun-sym-params f)))
        (for-each (lambda (a p)
                    (unify (var-sym-ty p) (infer-exp a c) (node-at a)
                           (format #f "in a call to `~a`" callee)))
                  args (fun-sym-params f))
        (fun-sym-result f))))))

;; The initialisers are put into declaration order, which is what lowering
;; wants.
(define-method (infer (e <e-record>) c)
  (let ((tyname (e-record-tyname e))
        (found (lookup-type c (e-record-tyname e) (node-at e)))
        (seen (make-hash-table)))
    (unless (is-a? found <ty-record>)
      (type-error (node-at e) "`~a` is not a record type" tyname))
    (for-each
     (lambda (f)
       (when (hash-ref seen (field-init-name f) #f)
         (type-error (field-init-at f) "field `~a` is given twice" (field-init-name f)))
       (when (< (record-index found (field-init-name f)) 0)
         (type-error (field-init-at f) "`~a` has no field `~a`"
                     (ty-record-name found) (field-init-name f)))
       (hash-set! seen (field-init-name f) f))
     (e-record-inits e))
    (set-e-record-inits!
     e
     (map (lambda (want)
            (let ((init (hash-ref seen (car want) #f)))
              (unless init (type-error (node-at e) "field `~a` is missing" (car want)))
              (unify (cdr want) (infer-exp (field-init-value init) c)
                     (field-init-at init) (format #f "in field `~a`" (car want)))
              init))
          (ty-record-fields found)))
    found))

(define-method (infer (e <e-index>) c)
  (let ((got (infer-exp (e-index-array e) c)))
    (unless (is-a? got <ty-array>)
      (type-error (node-at e) "`~a` is not an array" (show-ty got)))
    (unify 'int (infer-exp (e-index-index e) c) (node-at (e-index-index e))
           "as an array index")
    (ty-array-elem got)))

(define-method (infer (e <e-field>) c)
  (let ((got (infer-exp (e-field-record e) c)))
    (unless (is-a? got <ty-record>)
      (type-error (node-at e) "`~a` is not a record" (show-ty got)))
    (let ((ty (record-field-type got (e-field-select e))))
      (unless ty
        (type-error (node-at e) "`~a` has no field `~a`"
                    (ty-record-name got) (e-field-select e)))
      (set-exp-offset! e (record-index got (e-field-select e)))
      ty)))

(define-method (infer (e <e-neg>) c)
  (unify 'int (infer-exp (e-neg-operand e) c) (node-at e) "in a negation")
  'int)

(define-method (infer (e <e-bin>) c)
  (let* ((op (binary-op e))
         (lhs (binary-lhs e))
         (rhs (binary-rhs e))
         (l (infer-exp lhs c))
         (r (infer-exp rhs c)))
    (cond
     ((member op arithmetic)
      (unify 'int l (node-at lhs) (format #f "on the left of `~a`" op))
      (unify 'int r (node-at rhs) (format #f "on the right of `~a`" op))
      'int)
     ((string=? op "^")
      (unify 'string l (node-at lhs) "on the left of `^`")
      (unify 'string r (node-at rhs) "on the right of `^`")
      'string)
     ((member op ordering)
      (unless (memq l '(int string))
        (type-error (node-at e) "`~a` compares int or string, not `~a`" op (show-ty l)))
      (unify l r (node-at rhs) (format #f "on the right of `~a`" op))
      'bool)
     ((member op equality)
      (when (or (eq? l 'unit) (eq? r 'unit))
        (type-error (node-at e) "`~a` cannot compare `unit`" op))
      (unless (compatible? l r)
        (type-error (node-at e) "`~a` compares `~a` with `~a`" op (show-ty l) (show-ty r)))
      'bool)
     (else (type-error (node-at e) "unknown operator `~a`" op)))))

(define-method (infer (e <e-logic>) c)
  (let ((op (binary-op e)) (lhs (binary-lhs e)) (rhs (binary-rhs e)))
    (unify 'bool (infer-exp lhs c) (node-at lhs) (format #f "on the left of `~a`" op))
    (unify 'bool (infer-exp rhs c) (node-at rhs) (format #f "on the right of `~a`" op))
    'bool))

(define-method (infer (e <e-assign>) c)
  (let ((target (e-assign-target e))
        (v (e-assign-value e)))
    (let ((ty (infer-exp target c)))
      (when (is-a? target <e-var>)
        (let ((sym (exp-sym target)))
          (unless (var-sym-mutable? sym)
            (type-error (node-at e) "`~a` is a `val`, so it cannot be assigned"
                        (var-sym-name sym)))))
      (unify ty (infer-exp v c) (node-at v) "in an assignment")
      'unit)))

(define-method (infer (e <e-if>) c)
  (let ((cnd (e-if-test e)) (then (e-if-then e)) (els (e-if-else e)))
    (unify 'bool (infer-exp cnd c) (node-at cnd) "as an `if` condition")
    (let ((t (infer-exp then c)))
      (cond
       ((not els) (unify 'unit t (node-at then) "in an `if` with no `else`") 'unit)
       (else
        (let ((other (infer-exp els c)))
          (unless (compatible? t other)
            (type-error (node-at e) "the branches differ: `~a` and `~a`"
                        (show-ty t) (show-ty other)))
          (if (eq? t 'nil) other t)))))))

(define-method (infer (e <e-while>) c)
  (let ((cnd (e-while-test e)) (body (e-while-body e)))
    (unify 'bool (infer-exp cnd c) (node-at cnd) "as a `while` condition")
    (set! (checker-loops c) (+ 1 (checker-loops c)))
    (unify 'unit (infer-exp body c) (node-at body) "in a `while` body")
    (set! (checker-loops c) (- (checker-loops c) 1))
    'unit))

(define-method (infer (e <e-for>) c)
  (let ((lo (e-for-lo e)) (hi (e-for-hi e)) (body (e-for-body e)))
    (unify 'int (infer-exp lo c) (node-at lo) "as a `for` bound")
    (unify 'int (infer-exp hi c) (node-at hi) "as a `for` bound")
    (let ((sym (var-sym (e-for-binder e) 'int #f (checker-depth c))))
      (set-exp-sym! e sym)
      (push! c)
      (bind-val! c (e-for-binder e) sym)
      (set! (checker-loops c) (+ 1 (checker-loops c)))
      (unify 'unit (infer-exp body c) (node-at body) "in a `for` body")
      (set! (checker-loops c) (- (checker-loops c) 1))
      (pop! c)
      'unit)))

(define-method (infer (e <e-break>) c)
  (when (zero? (checker-loops c)) (type-error (node-at e) "`break` is outside any loop"))
  'unit)

(define-method (infer (e <e-seq>) c)
  (let loop ((items (e-seq-items e)) (ty 'unit))
    (if (null? items) ty (loop (cdr items) (infer-exp (car items) c)))))

(define-method (infer (e <e-let>) c)
  (push! c)
  (for-each (lambda (d) (declare d c)) (e-let-decls e))
  (let ((ty (infer-exp (e-let-body e) c)))
    (pop! c)
    ty))

;; Types the program in place: every node comes back with its type.
(define (check prog)
  (let ((c (make <checker>)))
    (set! (checker-scopes c) (list (prelude)))
    (push! c)
    (for-each (lambda (d) (declare d c)) prog)
    (pop! c)))

#lang racket/base

;; A Pratt parser.
;;
;; Every expression form is either a prefix form (in `atom`) or an infix one (in
;; `parse-exp`), and the table below is the whole of the precedence.  The prefix
;; forms that end in an expression — `if`, `while`, `for`, `:=` — take their tail
;; at binding power 0, so `if c then x := 1 else x := 2` reads the way it looks.

(require racket/list
         "diag.rkt"
         "lexer.rkt"
         "i64.rkt"
         (prefix-in ast: "ast.rkt"))

(provide parse parse-one-exp)

;; The left binding power and the power the right side is read at.  Left < right
;; is left-associative; left > right is right-associative, which only `:=` is.
(define binding-powers
  (hash 'ASSIGN '(2 . 1)
        'ORELSE '(4 . 5)
        'ANDALSO '(6 . 7)
        'EQ '(8 . 9) 'NE '(8 . 9) 'LT '(8 . 9) 'LE '(8 . 9) 'GT '(8 . 9) 'GE '(8 . 9)
        'CARET '(10 . 11)
        'PLUS '(12 . 13) 'MINUS '(12 . 13)
        'STAR '(14 . 15) 'SLASH '(14 . 15) 'MOD '(14 . 15)))

(define unary-bp 16)

(define binops
  (hash 'PLUS "+" 'MINUS "-" 'STAR "*" 'SLASH "/" 'MOD "mod" 'CARET "^"
        'EQ "=" 'NE "<>" 'LT "<" 'LE "<=" 'GT ">" 'GE ">="))

(define (declares? kind) (memq kind '(VAL VAR FUN TYPE)))

;; -- token plumbing ----------------------------------------------------------

;; Mutable, because a parser is a cursor over the tokens.
(struct parser (toks [pos #:mutable]))

(define (cur p) (vector-ref (parser-toks p) (parser-pos p)))
(define (kind p) (token-kind (cur p)))
(define (at? p k) (eq? (kind p) k))
(define (bump! p) (set-parser-pos! p (add1 (parser-pos p))))

(define (took? p k) (and (at? p k) (begin (bump! p) #t)))

;; What an error message calls the token that was found.
(define (found p)
  (define t (cur p))
  (case (token-kind t)
    [(EOF) "end of input"]
    [(STRING) (format "\"~a\"" (token-text t))]
    [else (format "`~a`" (token-text t))]))

(define (expect p k)
  (define t (cur p))
  (unless (took? p k)
    (parse-error (token-at t) "expected `~a`, found ~a" (hash-ref kind-text k) (found p)))
  t)

(define (expect-ident p)
  (define t (cur p))
  (unless (took? p 'IDENT)
    (parse-error (token-at t) "expected a name, found ~a" (found p)))
  t)

;; -- expressions -------------------------------------------------------------

(define (check-lvalue e)
  (define n (ast:exp-node e))
  (unless (or (ast:e:var? n) (ast:e:index? n) (ast:e:field? n))
    (parse-error (ast:exp-at e) "the left of `:=` is not assignable")))

;; Integers are 64 bits and wrap, so the largest literal is the one written
;; `~9223372036854775808`.
(define (integer t)
  (define v (string->number (token-text t) 10))
  (unless (and v (exact-nonnegative-integer? v) (< v (expt 2 64)))
    (parse-error (token-at t) "`~a` does not fit in 64 bits" (token-text t)))
  (wrap v))

(define (parse-exp p min-bp)
  (let loop ([left (atom p)])
    (define powers (hash-ref binding-powers (kind p) #f))
    (cond
      [(and powers (>= (car powers) min-bp))
       (define t (cur p))
       (define rbp (cdr powers))
       (bump! p)
       (define node
         (case (token-kind t)
           [(ASSIGN) (check-lvalue left) (ast:e:assign left (parse-exp p rbp))]
           [(ANDALSO ORELSE) (ast:e:logic (token-text t) left (parse-exp p rbp))]
           [else (ast:e:bin (hash-ref binops (token-kind t)) left (parse-exp p rbp))]))
       (loop (ast:make-exp (token-at t) node))]
      [else left])))

(define (atom p)
  (define t (cur p))
  (define start (token-at t))
  (case (token-kind t)
    [(INT) (bump! p) (postfix p (ast:make-exp start (ast:e:int (integer t))))]
    [(STRING) (bump! p) (postfix p (ast:make-exp start (ast:e:str (token-text t))))]
    [(TRUE FALSE)
     (bump! p)
     (ast:make-exp start (ast:e:bool (eq? (token-kind t) 'TRUE)))]
    [(NIL) (bump! p) (ast:make-exp start (ast:e:nil))]
    [(BREAK) (bump! p) (ast:make-exp start (ast:e:break))]
    [(TILDE) (bump! p) (ast:make-exp start (ast:e:neg (parse-exp p unary-bp)))]
    [(MINUS) (parse-error start "negation is written `~~`, not `-`")]
    [(LPAREN) (postfix p (parens p))]
    [(IDENT) (postfix p (named p))]
    [(IF) (if-exp p)]
    [(WHILE) (while-exp p)]
    [(FOR) (for-exp p)]
    [(LET) (let-exp p)]
    [else (parse-error start "expected an expression, found ~a" (found p))]))

(define (parens p)
  (define start (token-at (expect p 'LPAREN)))
  (cond
    [(took? p 'RPAREN) (ast:make-exp start (ast:e:unit))]
    [else
     (define items (sequence p 'RPAREN))
     (expect p 'RPAREN)
     (if (= 1 (length items)) (car items) (ast:make-exp start (ast:e:seq items)))]))

;; A trailing `;` is allowed, which is what the `stop` test is for.
(define (sequence p stop)
  (let loop ([items (list (parse-exp p 0))])
    (cond
      [(not (took? p 'SEMI)) (reverse items)]
      [(at? p stop) (reverse items)]
      [else (loop (cons (parse-exp p 0) items))])))

(define (named p)
  (define t (expect-ident p))
  (case (kind p)
    [(LPAREN)
     (bump! p)
     (define args
       (if (took? p 'RPAREN)
           '()
           (let loop ([acc (list (parse-exp p 0))])
             (cond [(took? p 'COMMA) (loop (cons (parse-exp p 0) acc))]
                   [else (expect p 'RPAREN) (reverse acc)]))))
     (ast:make-exp (token-at t) (ast:e:call (token-text t) args))]
    [(LBRACE)
     (bump! p)
     (define (one)
       (define fname (expect-ident p))
       (expect p 'EQ)
       (ast:field-init (token-text fname) (parse-exp p 0) (token-at fname)))
     (define inits
       (if (took? p 'RBRACE)
           '()
           (let loop ([acc (list (one))])
             (cond [(took? p 'COMMA) (loop (cons (one) acc))]
                   [else (expect p 'RBRACE) (reverse acc)]))))
     (ast:make-exp (token-at t) (ast:e:record (token-text t) inits))]
    [else (ast:make-exp (token-at t) (ast:e:var (token-text t)))]))

;; `[i]` and `.f` follow an atom, and only an atom: `nil.f` is not an expression.
(define (postfix p base)
  (let loop ([out base])
    (define start (token-at (cur p)))
    (case (kind p)
      [(LBRACK)
       (bump! p)
       (define index (parse-exp p 0))
       (expect p 'RBRACK)
       (loop (ast:make-exp start (ast:e:index out index)))]
      [(DOT)
       (bump! p)
       (define f (expect-ident p))
       (loop (ast:make-exp start (ast:e:field out (token-text f))))]
      [else out])))

(define (if-exp p)
  (define start (token-at (expect p 'IF)))
  (define c (parse-exp p 0))
  (expect p 'THEN)
  (define then (parse-exp p 0))
  (define els (and (took? p 'ELSE) (parse-exp p 0)))
  (ast:make-exp start (ast:e:if c then els)))

(define (while-exp p)
  (define start (token-at (expect p 'WHILE)))
  (define c (parse-exp p 0))
  (expect p 'DO)
  (ast:make-exp start (ast:e:while c (parse-exp p 0))))

(define (for-exp p)
  (define start (token-at (expect p 'FOR)))
  (define binder (expect-ident p))
  (expect p 'EQ)
  (define lo (parse-exp p 0))
  (expect p 'TO)
  (define hi (parse-exp p 0))
  (expect p 'DO)
  (ast:make-exp start (ast:e:for (token-text binder) lo hi (parse-exp p 0))))

(define (let-exp p)
  (define start (token-at (expect p 'LET)))
  (define decls
    (let loop ([acc '()])
      (if (declares? (kind p)) (loop (cons (decl p) acc)) (reverse acc))))
  (expect p 'IN)
  (define body
    (cond
      [(at? p 'END) (ast:make-exp start (ast:e:unit))]
      [else
       (define items (sequence p 'END))
       (if (= 1 (length items)) (car items) (ast:make-exp start (ast:e:seq items)))]))
  (expect p 'END)
  (ast:make-exp start (ast:e:let decls body)))

;; -- types -------------------------------------------------------------------

(define (ty p)
  (define start (token-at (cur p)))
  (let loop ([base (ty-atom p start)])
    (cond
      [(and (at? p 'IDENT) (string=? (token-text (cur p)) "array"))
       (bump! p)
       (loop (ast:t:array start base))]
      [else base])))

(define (ty-atom p start)
  (cond
    [(took? p 'LBRACE)
     (define (one)
       (define fname (expect-ident p))
       (expect p 'COLON)
       (ast:ty-field (token-text fname) (ty p) (token-at fname)))
     (define fields
       (if (took? p 'RBRACE)
           '()
           (let loop ([acc (list (one))])
             (cond [(took? p 'COMMA) (loop (cons (one) acc))]
                   [else (expect p 'RBRACE) (reverse acc)]))))
     (ast:t:record start fields)]
    [(took? p 'LPAREN)
     (define inner (ty p))
     (expect p 'RPAREN)
     inner]
    [else (ast:t:name start (token-text (expect-ident p)))]))

;; -- declarations ------------------------------------------------------------

(define (decl p)
  (case (kind p)
    [(TYPE) (type-decl p)]
    [(VAL VAR) (val-decl p)]
    [(FUN) (fun-decl p)]
    [else
     (parse-error (token-at (cur p))
                  "expected a declaration (`val`, `var`, `fun`, `type`), found ~a"
                  (found p))]))

;; `and` joins a group, and the group is one declaration: the names of a group
;; are all in scope in all of its bodies.
(define (group p one)
  (let loop ([acc (list (one p))])
    (if (took? p 'AND) (loop (cons (one p) acc)) (reverse acc))))

(define (type-decl p)
  (define start (token-at (expect p 'TYPE)))
  (ast:d:type start (group p type-bind)))

(define (type-bind p)
  (define name (expect-ident p))
  (expect p 'EQ)
  (ast:type-bind (token-text name) (ty p) (token-at name)))

(define (val-decl p)
  (define var? (at? p 'VAR))
  (define start (token-at (cur p)))
  (bump! p)
  (define name
    (cond [(took? p 'LPAREN) (expect p 'RPAREN) #f]
          [else (token-text (expect-ident p))]))
  (define written (and (took? p 'COLON) (ty p)))
  (expect p 'EQ)
  (ast:d:val start name written (parse-exp p 0) var? #f))

(define (fun-decl p)
  (define start (token-at (expect p 'FUN)))
  (ast:d:fun start (group p fun-bind)))

(define (fun-bind p)
  (define name (expect-ident p))
  (expect p 'LPAREN)
  (define (one)
    (define pname (expect-ident p))
    (expect p 'COLON)
    (ast:param (token-text pname) (ty p) (token-at pname) #f))
  (define params
    (if (took? p 'RPAREN)
        '()
        (let loop ([acc (list (one))])
          (cond [(took? p 'COMMA) (loop (cons (one) acc))]
                [else (expect p 'RPAREN) (reverse acc)]))))
  (define result (and (took? p 'COLON) (ty p)))
  (expect p 'EQ)
  (ast:fun-bind (token-text name) params result (parse-exp p 0) (token-at name) #f))

;; -- entry points ------------------------------------------------------------

(define (of-tokens toks) (parser (list->vector toks) 0))

(define (parse source)
  (define p (of-tokens (lex source)))
  (let loop ([acc '()])
    (if (at? p 'EOF) (reverse acc) (loop (cons (decl p) acc)))))

;; One expression — the tests use this, the compiler does not.
(define (parse-one-exp source)
  (define p (of-tokens (lex source)))
  (define e (parse-exp p 0))
  (unless (at? p 'EOF)
    (parse-error (token-at (cur p)) "unexpected ~a after the expression" (found p)))
  e)

;;; A Pratt parser.
;;;
;;; Every expression form is either a prefix form (in `atom`) or an infix one
;;; (in `parse-exp`), and the table below is the whole of the precedence.  The
;;; prefix forms that end in an expression — `if`, `while`, `for`, `:=` — take
;;; their tail at binding power 0, so `if c then x := 1 else x := 2` reads the
;;; way it looks.

(define-module (wolv parser)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (wolv diag)
  #:use-module (wolv lexer)
  #:use-module (wolv i64)
  #:use-module (wolv ast)
  #:export (parse parse-one-exp))

;; The left binding power and the power the right side is read at.  Left < right
;; is left-associative; left > right is right-associative, which only `:=` is.
(define binding-powers
  '((ASSIGN 2 . 1)
    (ORELSE 4 . 5)
    (ANDALSO 6 . 7)
    (EQ 8 . 9) (NE 8 . 9) (LT 8 . 9) (LE 8 . 9) (GT 8 . 9) (GE 8 . 9)
    (CARET 10 . 11)
    (PLUS 12 . 13) (MINUS 12 . 13)
    (STAR 14 . 15) (SLASH 14 . 15) (MOD 14 . 15)))

(define unary-bp 16)

(define binops
  '((PLUS . "+") (MINUS . "-") (STAR . "*") (SLASH . "/") (MOD . "mod")
    (CARET . "^") (EQ . "=") (NE . "<>") (LT . "<") (LE . "<=")
    (GT . ">") (GE . ">=")))

(define (declares? kind) (memq kind '(VAL VAR FUN TYPE)))

;; -- token plumbing ----------------------------------------------------------

;; Mutable, because a parser is a cursor over the tokens.
(define-class <parser> ()
  (toks #:init-keyword #:toks #:getter parser-toks)
  (pos #:init-value 0 #:accessor parser-pos))

(define (cur p) (vector-ref (parser-toks p) (parser-pos p)))
(define (kind p) (token-kind (cur p)))
(define (at? p k) (eq? (kind p) k))
(define (bump! p) (set! (parser-pos p) (+ 1 (parser-pos p))))

(define (took? p k) (and (at? p k) (begin (bump! p) #t)))

;; What an error message calls the token that was found.
(define (found p)
  (let ((t (cur p)))
    (case (token-kind t)
      ((EOF) "end of input")
      ((STRING) (format #f "\"~a\"" (token-text t)))
      (else (format #f "`~a`" (token-text t))))))

(define (expect p k)
  (let ((t (cur p)))
    (unless (took? p k)
      (parse-error (token-at t) "expected `~a`, found ~a" (kind-text k) (found p)))
    t))

(define (expect-ident p)
  (let ((t (cur p)))
    (unless (took? p 'IDENT)
      (parse-error (token-at t) "expected a name, found ~a" (found p)))
    t))

;; -- expressions -------------------------------------------------------------

(define (check-lvalue e)
  (unless (or (is-a? e <e-var>) (is-a? e <e-index>) (is-a? e <e-field>))
    (parse-error (node-at e) "the left of `:=` is not assignable")))

;; Integers are 64 bits and wrap, so the largest literal is the one written
;; `~9223372036854775808`.
(define (integer-of t)
  (let ((v (string->number (token-text t) 10)))
    (unless (and v (exact? v) (integer? v) (not (negative? v)) (< v (expt 2 64)))
      (parse-error (token-at t) "`~a` does not fit in 64 bits" (token-text t)))
    (wrap v)))

(define (parse-exp p min-bp)
  (let loop ((left (atom p)))
    (let ((powers (assq (kind p) binding-powers)))
      (cond
       ((and powers (>= (cadr powers) min-bp))
        (let* ((t (cur p))
               (rbp (cddr powers)))
          (bump! p)
          (loop
           (case (token-kind t)
             ((ASSIGN) (check-lvalue left)
                       (e-assign (token-at t) left (parse-exp p rbp)))
             ((ANDALSO ORELSE)
              (e-logic (token-at t) (token-text t) left (parse-exp p rbp)))
             (else
              (e-bin (token-at t) (cdr (assq (token-kind t) binops))
                     left (parse-exp p rbp)))))))
       (else left)))))

(define (atom p)
  (let* ((t (cur p))
         (start (token-at t)))
    (case (token-kind t)
      ((INT) (bump! p) (postfix p (e-int start (integer-of t))))
      ((STRING) (bump! p) (postfix p (e-str start (token-text t))))
      ((TRUE FALSE) (bump! p) (e-bool start (eq? (token-kind t) 'TRUE)))
      ((NIL) (bump! p) (e-nil start))
      ((BREAK) (bump! p) (e-break start))
      ((TILDE) (bump! p) (e-neg start (parse-exp p unary-bp)))
      ((MINUS) (parse-error start "negation is written `~~`, not `-`"))
      ((LPAREN) (postfix p (parens p)))
      ((IDENT) (postfix p (named p)))
      ((IF) (if-exp p))
      ((WHILE) (while-exp p))
      ((FOR) (for-exp p))
      ((LET) (let-exp p))
      (else (parse-error start "expected an expression, found ~a" (found p))))))

(define (parens p)
  (let ((start (token-at (expect p 'LPAREN))))
    (cond
     ((took? p 'RPAREN) (e-unit start))
     (else
      (let ((items (sequence p 'RPAREN)))
        (expect p 'RPAREN)
        (if (= 1 (length items)) (car items) (e-seq start items)))))))

;; A trailing `;` is allowed, which is what the `stop` test is for.
(define (sequence p stop)
  (let loop ((items (list (parse-exp p 0))))
    (cond
     ((not (took? p 'SEMI)) (reverse items))
     ((at? p stop) (reverse items))
     (else (loop (cons (parse-exp p 0) items))))))

;; A comma-separated list already inside its brackets, up to `close`.
(define (comma-list p close one)
  (if (took? p close)
      '()
      (let loop ((acc (list (one))))
        (cond ((took? p 'COMMA) (loop (cons (one) acc)))
              (else (expect p close) (reverse acc))))))

(define (named p)
  (let ((t (expect-ident p)))
    (case (kind p)
      ((LPAREN)
       (bump! p)
       (e-call (token-at t) (token-text t)
               (comma-list p 'RPAREN (lambda () (parse-exp p 0)))))
      ((LBRACE)
       (bump! p)
       (e-record (token-at t) (token-text t)
                 (comma-list p 'RBRACE
                             (lambda ()
                               (let ((fname (expect-ident p)))
                                 (expect p 'EQ)
                                 (field-init (token-text fname) (parse-exp p 0)
                                             (token-at fname)))))))
      (else (e-var (token-at t) (token-text t))))))

;; `[i]` and `.f` follow an atom, and only an atom: `nil.f` is not an
;; expression.
(define (postfix p base)
  (let loop ((out base))
    (let ((start (token-at (cur p))))
      (case (kind p)
        ((LBRACK)
         (bump! p)
         (let ((index (parse-exp p 0)))
           (expect p 'RBRACK)
           (loop (e-index start out index))))
        ((DOT)
         (bump! p)
         (let ((f (expect-ident p)))
           (loop (e-field start out (token-text f)))))
        (else out)))))

(define (if-exp p)
  (let* ((start (token-at (expect p 'IF)))
         (test (parse-exp p 0)))
    (expect p 'THEN)
    (let* ((then (parse-exp p 0))
           (els (and (took? p 'ELSE) (parse-exp p 0))))
      (e-if start test then els))))

(define (while-exp p)
  (let* ((start (token-at (expect p 'WHILE)))
         (test (parse-exp p 0)))
    (expect p 'DO)
    (e-while start test (parse-exp p 0))))

(define (for-exp p)
  (let* ((start (token-at (expect p 'FOR)))
         (binder (expect-ident p)))
    (expect p 'EQ)
    (let ((lo (parse-exp p 0)))
      (expect p 'TO)
      (let ((hi (parse-exp p 0)))
        (expect p 'DO)
        (e-for start (token-text binder) lo hi (parse-exp p 0))))))

(define (let-exp p)
  (let* ((start (token-at (expect p 'LET)))
         (decls (let loop ((acc '()))
                  (if (declares? (kind p)) (loop (cons (decl p) acc)) (reverse acc)))))
    (expect p 'IN)
    (let ((body (cond
                 ((at? p 'END) (e-unit start))
                 (else
                  (let ((items (sequence p 'END)))
                    (if (= 1 (length items)) (car items) (e-seq start items)))))))
      (expect p 'END)
      (e-let start decls body))))

;; -- types -------------------------------------------------------------------

(define (ty p)
  (let ((start (token-at (cur p))))
    (let loop ((base (ty-atom p start)))
      (cond
       ((and (at? p 'IDENT) (string=? (token-text (cur p)) "array"))
        (bump! p)
        (loop (t-array start base)))
       (else base)))))

(define (ty-atom p start)
  (cond
   ((took? p 'LBRACE)
    (t-record start
              (comma-list p 'RBRACE
                          (lambda ()
                            (let ((fname (expect-ident p)))
                              (expect p 'COLON)
                              (ty-field (token-text fname) (ty p) (token-at fname)))))))
   ((took? p 'LPAREN)
    (let ((inner (ty p)))
      (expect p 'RPAREN)
      inner))
   (else (t-name start (token-text (expect-ident p))))))

;; -- declarations ------------------------------------------------------------

(define (decl p)
  (case (kind p)
    ((TYPE) (type-decl p))
    ((VAL VAR) (val-decl p))
    ((FUN) (fun-decl p))
    (else
     (parse-error (token-at (cur p))
                  "expected a declaration (`val`, `var`, `fun`, `type`), found ~a"
                  (found p)))))

;; `and` joins a group, and the group is one declaration: the names of a group
;; are all in scope in all of its bodies.
(define (group p one)
  (let loop ((acc (list (one p))))
    (if (took? p 'AND) (loop (cons (one p) acc)) (reverse acc))))

(define (type-decl p)
  (let ((start (token-at (expect p 'TYPE))))
    (d-type start (group p one-type-bind))))

(define (one-type-bind p)
  (let ((name (expect-ident p)))
    (expect p 'EQ)
    (type-bind (token-text name) (ty p) (token-at name))))

(define (val-decl p)
  (let* ((var? (at? p 'VAR))
         (start (token-at (cur p))))
    (bump! p)
    (let* ((name (cond ((took? p 'LPAREN) (expect p 'RPAREN) #f)
                       (else (token-text (expect-ident p)))))
           (written (and (took? p 'COLON) (ty p))))
      (expect p 'EQ)
      (d-val start name written (parse-exp p 0) var?))))

(define (fun-decl p)
  (let ((start (token-at (expect p 'FUN))))
    (d-fun start (group p one-fun-bind))))

(define (one-fun-bind p)
  (let ((name (expect-ident p)))
    (expect p 'LPAREN)
    (let* ((params (comma-list p 'RPAREN
                               (lambda ()
                                 (let ((pname (expect-ident p)))
                                   (expect p 'COLON)
                                   (param (token-text pname) (ty p) (token-at pname))))))
           (result (and (took? p 'COLON) (ty p))))
      (expect p 'EQ)
      (fun-bind (token-text name) params result (parse-exp p 0) (token-at name)))))

;; -- entry points ------------------------------------------------------------

(define (of-tokens toks) (make <parser> #:toks (list->vector toks)))

(define (parse source)
  (let ((p (of-tokens (lex source))))
    (let loop ((acc '()))
      (if (at? p 'EOF) (reverse acc) (loop (cons (decl p) acc))))))

;; One expression — the tests use this, the compiler does not.
(define (parse-one-exp source)
  (let* ((p (of-tokens (lex source)))
         (e (parse-exp p 0)))
    (unless (at? p 'EOF)
      (parse-error (token-at (cur p)) "unexpected ~a after the expression" (found p)))
    e))

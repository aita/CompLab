;;; Tokens, and the hand-written scanner that produces them.
;;;
;;; A kind is a symbol, so the name a dump prints is the kind itself written
;;; down and there is no second table to keep in step with the first.
;;; `kind-text` is the other direction — what an error message calls a kind —
;;; and it is the only table here.
;;;
;;; A Scheme string is code points, as Python's is, so the scanner steps by
;;; characters and never counts UTF-8 widths.  A string literal is the
;;; exception: `size`, `ord` and `substring` count bytes at run time, so a
;;; literal is built as bytes, one character per byte, which is what the dump
;;; and the emitter expect.

(define-module (wolv lexer)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (find))
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 format)
  #:use-module (wolv diag)
  #:export (<token> token token-kind token-text token-at
            lex kind-text keywords punctuation dump))

(define-class <token> ()
  (kind #:init-keyword #:kind #:getter token-kind)
  (text #:init-keyword #:text #:getter token-text)
  (at #:init-keyword #:at #:getter token-at))

(define (token kind text at) (make <token> #:kind kind #:text text #:at at))

;; What an error message calls each kind.
(define kind-texts
  '((INT . "an integer") (STRING . "a string") (IDENT . "an identifier")
    (EOF . "end of input")
    (AND . "and") (ANDALSO . "andalso") (BREAK . "break") (DO . "do")
    (ELSE . "else") (END . "end") (FALSE . "false") (FOR . "for") (FUN . "fun")
    (IF . "if") (IN . "in") (LET . "let") (MOD . "mod") (NIL . "nil")
    (ORELSE . "orelse") (THEN . "then") (TO . "to") (TRUE . "true")
    (TYPE . "type") (VAL . "val") (VAR . "var") (WHILE . "while")
    (LPAREN . "(") (RPAREN . ")") (LBRACK . "[") (RBRACK . "]")
    (LBRACE . "{") (RBRACE . "}") (COMMA . ",") (COLON . ":") (SEMI . ";")
    (DOT . ".") (ASSIGN . ":=") (EQ . "=") (NE . "<>") (LE . "<=") (LT . "<")
    (GE . ">=") (GT . ">") (PLUS . "+") (MINUS . "-") (STAR . "*")
    (SLASH . "/") (CARET . "^") (TILDE . "~")))

(define (kind-text kind) (cdr (assq kind kind-texts)))

(define keywords
  '(AND ANDALSO BREAK DO ELSE END FALSE FOR FUN IF IN LET MOD
    NIL ORELSE THEN TO TRUE TYPE VAL VAR WHILE))

;; Longest first, so that `:=` beats `:` and `<=` beats `<`.
(define punctuation
  '(ASSIGN NE LE GE
    LPAREN RPAREN LBRACK RBRACK LBRACE RBRACE COMMA COLON SEMI DOT
    EQ LT GT PLUS MINUS STAR SLASH CARET TILDE))

(define escapes
  `((#\n . #\newline) (#\t . #\tab) (#\r . #\return) (#\" . #\") (#\\ . #\\)))

;; The letter and digit categories Python's `isalpha` and `isdigit` are, which
;; Guile answers directly.
(define (letter? c) (char-alphabetic? c))
(define (digit? c) (char-numeric? c))

;; -- the scanner -------------------------------------------------------------

;; Mutable, because a scanner is a cursor: `pos` is how far it has read and
;; `line`/`col` are where that is.
(define-class <scanner> ()
  (src #:init-keyword #:src #:getter scanner-src)
  (pos #:init-value 0 #:accessor scanner-pos)
  (line #:init-value 1 #:accessor scanner-line)
  (col #:init-value 1 #:accessor scanner-col))

(define (done? s) (>= (scanner-pos s) (string-length (scanner-src s))))
(define (here s) (string-ref (scanner-src s) (scanner-pos s)))
(define (at s) (span (scanner-line s) (scanner-col s)))

(define (step s)
  (if (char=? (here s) #\newline)
      (begin (set! (scanner-line s) (+ 1 (scanner-line s)))
             (set! (scanner-col s) 1))
      (set! (scanner-col s) (+ 1 (scanner-col s))))
  (set! (scanner-pos s) (+ 1 (scanner-pos s))))

(define (advance s n) (do ((i 0 (+ i 1))) ((= i n)) (step s)))

(define (starts-with? s prefix)
  (let* ((from (scanner-pos s))
         (to (+ from (string-length prefix))))
    (and (<= to (string-length (scanner-src s)))
         (string=? (substring (scanner-src s) from to) prefix))))

;; -- what is skipped ---------------------------------------------------------

(define (skip-trivia s)
  (when (not (done? s))
    (cond
     ((memv (here s) '(#\space #\tab #\return #\newline)) (step s) (skip-trivia s))
     ((starts-with? s "(*") (comment s) (skip-trivia s))
     (else *unspecified*))))

;; Comments nest, so the depth is counted rather than the first `*)` taken.
(define (comment s)
  (let ((start (at s)))
    (let loop ((depth 0))
      (cond
       ((done? s) (lex-error start "unterminated comment"))
       ((starts-with? s "(*") (advance s 2) (loop (+ depth 1)))
       ((starts-with? s "*)")
        (advance s 2)
        (when (> (- depth 1) 0) (loop (- depth 1))))
       (else (step s) (loop depth))))))

;; -- the pieces --------------------------------------------------------------

(define (scan-number s start)
  (let ((from (scanner-pos s)))
    (let loop () (when (and (not (done? s)) (digit? (here s))) (step s) (loop)))
    (let ((body (substring (scanner-src s) from (scanner-pos s))))
      (when (and (not (done? s)) (or (letter? (here s)) (char=? (here s) #\_)))
        (lex-error start "`~a~a` is not a number" body (here s)))
      (token 'INT body start))))

(define (scan-word s start)
  (define (continues? c)
    (or (letter? c) (digit? c) (char=? c #\_) (char=? c #\')))
  (let ((from (scanner-pos s)))
    (let loop () (when (and (not (done? s)) (continues? (here s))) (step s) (loop)))
    (let* ((body (substring (scanner-src s) from (scanner-pos s)))
           (keyword (find (lambda (k) (string=? (kind-text k) body)) keywords)))
      (token (or keyword 'IDENT) body start))))

;; What follows a backslash, as the one byte it names.
(define (scan-escape s)
  (when (done? s) (lex-error (at s) "unterminated escape"))
  (let ((c (here s)))
    (cond
     ((digit? c)
      (let* ((src (scanner-src s))
             (from (scanner-pos s))
             (digits (and (<= (+ from 3) (string-length src))
                          (let ((three (substring src from (+ from 3))))
                            (and (string-every (lambda (d) (char<=? #\0 d #\9)) three)
                                 (string->number three))))))
        (if (and digits (< digits 256))
            (begin (advance s 3) (integer->char digits))
            (lex-error (at s) "a numeric escape is three digits, `\\065`"))))
     ((and (char<? c (integer->char 128)) (assv c escapes))
      => (lambda (named) (step s) (cdr named)))
     (else (lex-error (at s) "unknown escape `\\~a`" c)))))

;; A literal is a sequence of bytes: source text contributes its UTF-8 encoding,
;; and `\ddd` names one byte.  Each byte becomes one character of the result, so
;; `string-length` is the length the run time will measure.
(define (scan-string s start)
  (step s)
  (let ((out (open-output-string)))
    (let loop ()
      (when (done? s) (lex-error start "unterminated string"))
      (let ((c (here s)))
        (cond
         ((char=? c #\") (step s))
         ((char=? c #\newline) (lex-error (at s) "a string may not span lines"))
         ((char=? c #\\) (step s) (write-char (scan-escape s) out) (loop))
         (else
          (let ((bytes (string->utf8 (string c))))
            (do ((i 0 (+ i 1))) ((= i (bytevector-length bytes)))
              (write-char (integer->char (bytevector-u8-ref bytes i)) out)))
          (step s)
          (loop)))))
    (token 'STRING (get-output-string out) start)))

(define (next s)
  (skip-trivia s)
  (let ((start (at s)))
    (cond
     ((done? s) (token 'EOF "" start))
     ((digit? (here s)) (scan-number s start))
     ((or (letter? (here s)) (char=? (here s) #\_)) (scan-word s start))
     ((char=? (here s) #\") (scan-string s start))
     (else
      (let ((kind (find (lambda (k) (starts-with? s (kind-text k))) punctuation)))
        (unless kind (lex-error start "stray character `~a`" (here s)))
        (let ((text (kind-text kind)))
          (advance s (string-length text))
          (token kind text start)))))))

;; Source text into tokens, in one pass, no regexes.
(define (lex source)
  (let ((s (make <scanner> #:src source)))
    (let loop ((acc '()))
      (let ((t (next s)))
        (if (eq? (token-kind t) 'EOF)
            (reverse (cons t acc))
            (loop (cons t acc)))))))

(define (dump tokens)
  (string-join
   (map (lambda (t)
          (format #f "~a\t~a\t~a" (show-span (token-at t))
                  (token-kind t) (token-text t)))
        tokens)
   "\n"))

#lang racket/base

;; Tokens, and the hand-written scanner that produces them.
;;
;; A kind is a symbol, so the name a dump prints is the kind itself written down
;; and there is no second table to keep in step with the first.  `kind-text` is
;; the other direction — what an error message calls a kind — and it is the only
;; table here.
;;
;; A Racket string is code points, as Python's is, so the scanner steps by
;; characters and never counts UTF-8 widths.  A string literal is the exception:
;; `size`, `ord` and `substring` count bytes at run time, so a literal is built as
;; bytes, one character per byte, which is what the dump and the emitter expect.

(require racket/list
         racket/string
         "diag.rkt")

(provide (struct-out token)
         lex
         kind-text
         keywords
         punctuation
         dump)

(struct token (kind text at) #:transparent)

;; What an error message calls each kind.
(define kind-text
  (hash 'INT "an integer" 'STRING "a string" 'IDENT "an identifier" 'EOF "end of input"
        'AND "and" 'ANDALSO "andalso" 'BREAK "break" 'DO "do" 'ELSE "else" 'END "end"
        'FALSE "false" 'FOR "for" 'FUN "fun" 'IF "if" 'IN "in" 'LET "let" 'MOD "mod"
        'NIL "nil" 'ORELSE "orelse" 'THEN "then" 'TO "to" 'TRUE "true" 'TYPE "type"
        'VAL "val" 'VAR "var" 'WHILE "while"
        'LPAREN "(" 'RPAREN ")" 'LBRACK "[" 'RBRACK "]" 'LBRACE "{" 'RBRACE "}"
        'COMMA "," 'COLON ":" 'SEMI ";" 'DOT "." 'ASSIGN ":=" 'EQ "=" 'NE "<>"
        'LE "<=" 'LT "<" 'GE ">=" 'GT ">" 'PLUS "+" 'MINUS "-" 'STAR "*" 'SLASH "/"
        'CARET "^" 'TILDE "~"))

(define keywords
  '(AND ANDALSO BREAK DO ELSE END FALSE FOR FUN IF IN LET MOD
    NIL ORELSE THEN TO TRUE TYPE VAL VAR WHILE))

;; Longest first, so that `:=` beats `:` and `<=` beats `<`.
(define punctuation
  '(ASSIGN NE LE GE
    LPAREN RPAREN LBRACK RBRACK LBRACE RBRACE COMMA COLON SEMI DOT
    EQ LT GT PLUS MINUS STAR SLASH CARET TILDE))

(define escapes (hash #\n #\newline #\t #\tab #\r #\return #\" #\" #\\ #\\))

;; The letter and digit categories Python's `isalpha` and `isdigit` are, which
;; Racket answers directly.
(define (letter? c) (memq (char-general-category c) '(lu ll lt lm lo)))
(define (digit? c) (eq? (char-general-category c) 'nd))

;; -- the scanner -------------------------------------------------------------

;; Mutable, because a scanner is a cursor: `pos` is how far it has read and
;; `line`/`col` are where that is.
(struct scanner (src [pos #:mutable] [line #:mutable] [col #:mutable]))

(define (done? s) (>= (scanner-pos s) (string-length (scanner-src s))))

(define (here s) (string-ref (scanner-src s) (scanner-pos s)))

(define (at s) (span (scanner-line s) (scanner-col s)))

(define (step s)
  (cond
    [(char=? (here s) #\newline)
     (set-scanner-line! s (add1 (scanner-line s)))
     (set-scanner-col! s 1)]
    [else (set-scanner-col! s (add1 (scanner-col s)))])
  (set-scanner-pos! s (add1 (scanner-pos s))))

(define (advance s n) (for ([_ (in-range n)]) (step s)))

(define (starts-with? s prefix)
  (define from (scanner-pos s))
  (define to (+ from (string-length prefix)))
  (and (<= to (string-length (scanner-src s)))
       (string=? (substring (scanner-src s) from to) prefix)))

;; -- what is skipped ---------------------------------------------------------

(define (skip-trivia s)
  (when (not (done? s))
    (cond
      [(memv (here s) '(#\space #\tab #\return #\newline)) (step s) (skip-trivia s)]
      [(starts-with? s "(*") (comment s) (skip-trivia s)]
      [else (void)])))

;; Comments nest, so the depth is counted rather than the first `*)` taken.
(define (comment s)
  (define start (at s))
  (let loop ([depth 0])
    (cond
      [(and (> depth 0) (done? s)) (lex-error start "unterminated comment")]
      [(done? s) (lex-error start "unterminated comment")]
      [(starts-with? s "(*") (advance s 2) (loop (add1 depth))]
      [(starts-with? s "*)")
       (advance s 2)
       (when (> (sub1 depth) 0) (loop (sub1 depth)))]
      [else (step s) (loop depth)])))

;; -- the pieces --------------------------------------------------------------

(define (scan-number s start)
  (define from (scanner-pos s))
  (let loop () (when (and (not (done? s)) (digit? (here s))) (step s) (loop)))
  (define body (substring (scanner-src s) from (scanner-pos s)))
  (when (and (not (done? s)) (or (letter? (here s)) (char=? (here s) #\_)))
    (lex-error start "`~a~a` is not a number" body (here s)))
  (token 'INT body start))

(define (scan-word s start)
  (define from (scanner-pos s))
  (define (continues? c) (or (letter? c) (digit? c) (char=? c #\_) (char=? c #\')))
  (let loop () (when (and (not (done? s)) (continues? (here s))) (step s) (loop)))
  (define body (substring (scanner-src s) from (scanner-pos s)))
  (define keyword (findf (λ (k) (string=? (hash-ref kind-text k) body)) keywords))
  (token (or keyword 'IDENT) body start))

;; What follows a backslash, as the one byte it names.
(define (scan-escape s)
  (when (done? s) (lex-error (at s) "unterminated escape"))
  (define c (here s))
  (cond
    [(digit? c)
     (define src (scanner-src s))
     (define from (scanner-pos s))
     (define digits
       (and (<= (+ from 3) (string-length src))
            (let ([three (substring src from (+ from 3))])
              (and (for/and ([d (in-string three)]) (char<=? #\0 d #\9))
                   (string->number three)))))
     (cond
       [(and digits (< digits 256)) (advance s 3) (integer->char digits)]
       [else (lex-error (at s) "a numeric escape is three digits, `\\065`")])]
    [(and (char<? c (integer->char 128)) (hash-ref escapes c #f))
     => (λ (named) (step s) named)]
    [else (lex-error (at s) "unknown escape `\\~a`" c)]))

;; A literal is a sequence of bytes: source text contributes its UTF-8 encoding,
;; and `\ddd` names one byte.  Each byte becomes one character of the result, so
;; `string-length` is the length the run time will measure.
(define (scan-string s start)
  (step s)
  (define out (open-output-string))
  (let loop ()
    (when (done? s) (lex-error start "unterminated string"))
    (define c (here s))
    (cond
      [(char=? c #\") (step s)]
      [(char=? c #\newline) (lex-error (at s) "a string may not span lines")]
      [(char=? c #\\) (step s) (write-char (scan-escape s) out) (loop)]
      [else
       (for ([b (in-bytes (string->bytes/utf-8 (string c)))])
         (write-char (integer->char b) out))
       (step s)
       (loop)]))
  (token 'STRING (get-output-string out) start))

(define (next s)
  (skip-trivia s)
  (define start (at s))
  (cond
    [(done? s) (token 'EOF "" start)]
    [(digit? (here s)) (scan-number s start)]
    [(or (letter? (here s)) (char=? (here s) #\_)) (scan-word s start)]
    [(char=? (here s) #\") (scan-string s start)]
    [else
     (define kind
       (findf (λ (k) (starts-with? s (hash-ref kind-text k))) punctuation))
     (unless kind (lex-error start "stray character `~a`" (here s)))
     (define text (hash-ref kind-text kind))
     (advance s (string-length text))
     (token kind text start)]))

;; Source text into tokens, in one pass, no regexes.
(define (lex source)
  (define s (scanner source 0 1 1))
  (let loop ([acc '()])
    (define t (next s))
    (if (eq? (token-kind t) 'EOF)
        (reverse (cons t acc))
        (loop (cons t acc)))))

(define (dump tokens)
  (string-join
   (for/list ([t (in-list tokens)])
     (format "~a\t~a\t~a" (show-span (token-at t)) (token-kind t) (token-text t)))
   "\n"))

#lang racket/base

;; An indented dump of the typed syntax tree, for `wolv emit -s ast`.

(require racket/string
         "types.rkt"
         (prefix-in ast: "ast.rkt"))

(provide show-program quoted)

;; A string literal, written the way the Python tree writes it, so that a dump
;; taken from either is the same dump.  Every character of one is a byte, and a
;; byte that stands for nothing printable is shown as `\xNN`.
;;
;; The other ports ask a Unicode database which bytes those are.  Over the range
;; a literal can hold — U+0000 to U+00FF — the answer is four fixed ranges: the
;; C0 and C1 controls, no-break space, and the soft hyphen.
(define (quoted text)
  (define quote-char
    (if (and (regexp-match? #rx"'" text) (not (regexp-match? #rx"\"" text))) #\" #\'))
  (define out (open-output-string))
  (write-char quote-char out)
  (for ([c (in-string text)])
    (define n (char->integer c))
    (cond
      [(or (char=? c quote-char) (char=? c #\\)) (write-char #\\ out) (write-char c out)]
      [(= n 10) (write-string "\\n" out)]
      [(= n 13) (write-string "\\r" out)]
      [(= n 9) (write-string "\\t" out)]
      [(or (<= n #x1F) (<= #x7F n #xA0) (= n #xAD))
       (write-string (format "\\x~a" (~hex n)) out)]
      [else (write-char c out)]))
  (write-char quote-char out)
  (get-output-string out))

(define (~hex n)
  (define s (number->string n 16))
  (if (< (string-length s) 2) (string-append "0" s) s))

(define (escapes sym)
  (if (and sym (var-sym? sym) (var-sym-escapes? sym)) " (escapes)" ""))

(define (show-program prog)
  (define lines '())
  (define (put depth text)
    (set! lines (cons (string-append (make-string (* 2 depth) #\space) text) lines)))

  (define (show-type e)
    (if (ast:exp-ty e) (string-append " : " (show-ty (ast:exp-ty e))) ""))

  (define (decl depth d)
    (cond
      [(ast:d:type? d)
       (for ([b (in-list (ast:d:type-binds d))])
         (put depth (string-append "type " (ast:type-bind-name b))))]
      [(ast:d:val? d)
       (define keyword (if (ast:d:val-var? d) "var" "val"))
       (define name (or (ast:d:val-name d) "()"))
       (put depth (string-append keyword " " name (escapes (ast:d:val-sym d))))
       (expr (add1 depth) (ast:d:val-init d))]
      [else
       (for ([b (in-list (ast:d:fun-binds d))])
         (define params
           (string-join
            (for/list ([p (in-list (ast:fun-bind-params b))])
              (string-append (ast:param-name p) (escapes (ast:param-sym p))))
            ", "))
         (define result
           (if (ast:fun-bind-sym b) (show-ty (fun-sym-result (ast:fun-bind-sym b))) "?"))
         (put depth (format "fun ~a(~a) : ~a" (ast:fun-bind-label b) params result))
         (expr (add1 depth) (ast:fun-bind-body b)))]))

  (define (expr depth e)
    (define n (ast:exp-node e))
    (define (kids . es) (for ([k (in-list es)]) (expr (add1 depth) k)))
    (cond
      [(ast:e:int? n) (put depth (format "int ~a" (ast:e:int-value n)))]
      [(ast:e:str? n) (put depth (string-append "string " (quoted (ast:e:str-value n))))]
      [(ast:e:bool? n)
       (put depth (string-append "bool " (if (ast:e:bool-value n) "true" "false")))]
      [(ast:e:nil? n) (put depth "nil")]
      [(ast:e:unit? n) (put depth "()")]
      [(ast:e:var? n) (put depth (string-append "var " (ast:e:var-name n) (show-type e)))]
      [(ast:e:call? n)
       (put depth (string-append "call " (ast:e:call-callee n) (show-type e)))
       (for ([a (in-list (ast:e:call-args n))]) (expr (add1 depth) a))]
      [(ast:e:record? n)
       (put depth (string-append "record " (ast:e:record-tyname n) (show-type e)))
       (for ([f (in-list (ast:e:record-inits n))])
         (put (add1 depth) (string-append (ast:field-init-name f) " ="))
         (expr (+ 2 depth) (ast:field-init-value f)))]
      [(ast:e:index? n)
       (put depth (string-append "index" (show-type e)))
       (kids (ast:e:index-array n) (ast:e:index-index n))]
      [(ast:e:field? n)
       (put depth (string-append "field ." (ast:e:field-select n) (show-type e)))
       (kids (ast:e:field-record n))]
      [(ast:e:neg? n) (put depth "neg") (kids (ast:e:neg-operand n))]
      [(ast:e:bin? n)
       (put depth (string-append (ast:e:bin-op n) (show-type e)))
       (kids (ast:e:bin-lhs n) (ast:e:bin-rhs n))]
      [(ast:e:logic? n)
       (put depth (string-append (ast:e:logic-op n) (show-type e)))
       (kids (ast:e:logic-lhs n) (ast:e:logic-rhs n))]
      [(ast:e:assign? n)
       (put depth ":=")
       (kids (ast:e:assign-target n) (ast:e:assign-value n))]
      [(ast:e:if? n)
       (put depth (string-append "if" (show-type e)))
       (kids (ast:e:if-cond n) (ast:e:if-then n))
       (when (ast:e:if-els n) (expr (add1 depth) (ast:e:if-els n)))]
      [(ast:e:while? n)
       (put depth "while")
       (kids (ast:e:while-cond n) (ast:e:while-body n))]
      [(ast:e:for? n)
       (put depth (string-append "for " (ast:e:for-binder n) (escapes (ast:exp-sym e))))
       (kids (ast:e:for-lo n) (ast:e:for-hi n) (ast:e:for-body n))]
      [(ast:e:break? n) (put depth "break")]
      [(ast:e:seq? n)
       (put depth (string-append "seq" (show-type e)))
       (for ([item (in-list (ast:e:seq-items n))]) (expr (add1 depth) item))]
      [else
       (put depth (string-append "let" (show-type e)))
       (for ([d (in-list (ast:e:let-decls n))]) (decl (add1 depth) d))
       (put depth "in")
       (expr (add1 depth) (ast:e:let-body n))]))

  (for ([d (in-list prog)]) (decl 0 d))
  (string-append (string-join (reverse lines) "\n") "\n"))

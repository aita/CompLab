#lang racket/base

;; An indented dump of the typed syntax tree, for `wolv emit -s ast`.

(require racket/match
         racket/string
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
    (match d
      [(ast:d:type _ binds)
       (for ([b (in-list binds)])
         (put depth (string-append "type " (ast:type-bind-name b))))]
      [(ast:d:val _ name _ init var? sym)
       (put depth (string-append (if var? "var" "val") " " (or name "()") (escapes sym)))
       (expr (add1 depth) init)]
      [(ast:d:fun _ binds)
       (for ([b (in-list binds)])
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
    (define (kids . es) (for ([k (in-list es)]) (expr (add1 depth) k)))
    (match (ast:exp-node e)
      [(ast:e:int value) (put depth (format "int ~a" value))]
      [(ast:e:str value) (put depth (string-append "string " (quoted value)))]
      [(ast:e:bool value) (put depth (string-append "bool " (if value "true" "false")))]
      [(ast:e:nil) (put depth "nil")]
      [(ast:e:unit) (put depth "()")]
      [(ast:e:var name) (put depth (string-append "var " name (show-type e)))]
      [(ast:e:call callee args)
       (put depth (string-append "call " callee (show-type e)))
       (for ([a (in-list args)]) (expr (add1 depth) a))]
      [(ast:e:record tyname inits)
       (put depth (string-append "record " tyname (show-type e)))
       (for ([f (in-list inits)])
         (put (add1 depth) (string-append (ast:field-init-name f) " ="))
         (expr (+ 2 depth) (ast:field-init-value f)))]
      [(ast:e:index array index)
       (put depth (string-append "index" (show-type e)))
       (kids array index)]
      [(ast:e:field record select)
       (put depth (string-append "field ." select (show-type e)))
       (kids record)]
      [(ast:e:neg operand) (put depth "neg") (kids operand)]
      [(or (ast:e:bin op lhs rhs) (ast:e:logic op lhs rhs))
       (put depth (string-append op (show-type e)))
       (kids lhs rhs)]
      [(ast:e:assign target value)
       (put depth ":=")
       (kids target value)]
      [(ast:e:if cnd then els)
       (put depth (string-append "if" (show-type e)))
       (kids cnd then)
       (when els (expr (add1 depth) els))]
      [(ast:e:while cnd body)
       (put depth "while")
       (kids cnd body)]
      [(ast:e:for binder lo hi body)
       (put depth (string-append "for " binder (escapes (ast:exp-sym e))))
       (kids lo hi body)]
      [(ast:e:break) (put depth "break")]
      [(ast:e:seq items)
       (put depth (string-append "seq" (show-type e)))
       (for ([item (in-list items)]) (expr (add1 depth) item))]
      [(ast:e:let bound body)
       (put depth (string-append "let" (show-type e)))
       (for ([d (in-list bound)]) (decl (add1 depth) d))
       (put depth "in")
       (expr (add1 depth) body)]))

  (for ([d (in-list prog)]) (decl 0 d))
  (string-append (string-join (reverse lines) "\n") "\n"))

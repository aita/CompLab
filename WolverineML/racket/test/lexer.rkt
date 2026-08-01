#lang racket/base

(require rackunit
         racket/list
         "../src/diag.rkt"
         "../src/lexer.rkt")

(provide lexer-tests)

(define (kinds source) (for/list ([t (in-list (lex source))]) (token-kind t)))

(define (lex-error? message)
  (λ (e) (and (exn:wolv? e) (eq? (exn:wolv-kind e) 'lex)
              (regexp-match? (regexp-quote message) (exn-message e)))))

(define lexer-tests
  (test-suite
   "lexer"

   (test-case "keywords are not identifiers"
     (check-equal? (kinds "let val") '(LET VAL EOF))
     (check-equal? (kinds "letter") '(IDENT EOF)))

   (test-case "the longest punctuation wins"
     (check-equal? (kinds ":= : <= < <> >=") '(ASSIGN COLON LE LT NE GE EOF)))

   (test-case "comments nest"
     (check-equal? (kinds "(* a (* b *) c *) 1") '(INT EOF)))

   (test-case "an unterminated comment is an error"
     (check-exn (lex-error? "unterminated comment") (λ () (lex "(* forever"))))

   (test-case "string escapes"
     (check-equal? (token-text (first (lex "\"a\\nb\\t\\\"\\\\\\065\""))) "a\nb\t\"\\A"))

   (test-case "a string is bytes"
     ;; Source text contributes its UTF-8; `\ddd` names one byte of it.
     (check-equal? (token-text (first (lex "\"\\230\\151\\165\"")))
                   (token-text (first (lex "\"日\""))))
     (check-equal? (string-length (token-text (first (lex "\"日本語\"")))) 9))

   (test-case "a numeric escape is three digits"
     (check-exn (lex-error? "three digits") (λ () (lex "\"\\65\""))))

   (test-case "a string may not span lines"
     (check-exn (lex-error? "may not span lines") (λ () (lex "\"one\ntwo\""))))

   (test-case "spans count from one"
     (define tokens (lex "val\n  x"))
     (check-equal? (span-line (token-at (first tokens))) 1)
     (check-equal? (span-col (token-at (first tokens))) 1)
     (check-equal? (span-line (token-at (second tokens))) 2)
     (check-equal? (span-col (token-at (second tokens))) 3))

   (test-case "a number may not run into a name"
     (check-exn (lex-error? "is not a number") (λ () (lex "12ab"))))

   (test-case "a stray character is an error"
     (check-exn (lex-error? "stray character") (λ () (lex "a ? b"))))))

(module+ test (require rackunit/text-ui) (void (run-tests lexer-tests)))

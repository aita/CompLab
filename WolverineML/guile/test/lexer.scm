;;; The scanner.

(use-modules (srfi srfi-1)
             (srfi srfi-64)
             (harness)
             (wolv diag)
             (wolv lexer))

(define (kinds source) (map token-kind (lex source)))

(with-suite
 "lexer"
 (lambda ()

   (test-equal "keywords are not identifiers" '(LET VAL EOF) (kinds "let val"))
   (test-equal "a keyword's prefix is not one" '(IDENT EOF) (kinds "letter"))

   (test-equal "the longest punctuation wins"
     '(ASSIGN COLON LE LT NE GE EOF)
     (kinds ":= : <= < <> >="))

   (test-equal "comments nest" '(INT EOF) (kinds "(* a (* b *) c *) 1"))

   (test-assert "an unterminated comment is an error"
     (raises? 'lex "unterminated comment" (lambda () (lex "(* forever"))))

   (test-equal "string escapes"
     "a\nb\t\"\\A"
     (token-text (first (lex "\"a\\nb\\t\\\"\\\\\\065\""))))

   ;; Source text contributes its UTF-8; `\ddd` names one byte of it.
   (test-equal "a string is bytes"
     (token-text (first (lex "\"日\"")))
     (token-text (first (lex "\"\\230\\151\\165\""))))

   (test-equal "and its length is counted in them"
     9
     (string-length (token-text (first (lex "\"日本語\"")))))

   (test-assert "a numeric escape is three digits"
     (raises? 'lex "three digits" (lambda () (lex "\"\\65\""))))

   (test-assert "a string may not span lines"
     (raises? 'lex "may not span lines" (lambda () (lex "\"one\ntwo\""))))

   (test-equal "spans count from one"
     '(1 1 2 3)
     (let ((tokens (lex "val\n  x")))
       (list (span-line (token-at (first tokens)))
             (span-col (token-at (first tokens)))
             (span-line (token-at (second tokens)))
             (span-col (token-at (second tokens))))))

   (test-assert "a number may not run into a name"
     (raises? 'lex "is not a number" (lambda () (lex "12ab"))))

   (test-assert "a stray character is an error"
     (raises? 'lex "stray character" (lambda () (lex "a ? b"))))))

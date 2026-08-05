(defpackage #:wolv.test.lexer
  (:use #:cl #:wolv.test)
  (:local-nicknames (#:diag #:wolv.diag) (#:lex #:wolv.lexer)))

(in-package #:wolv.test.lexer)

(in-suite "lexer")

(defun kinds (source) (mapcar #'lex:token-kind (lex:lex source)))
(defun texts (source) (mapcar #'lex:token-text (lex:lex source)))

(deftest "keywords are not identifiers"
  (is= '(:let :val :eof) (kinds "let val"))
  (is= '(:ident :eof) (kinds "letter")))

(deftest "the longest punctuation wins"
  (is= '(:assign :colon :le :lt :ne :ge :eof) (kinds ":= : <= < <> >=")))

(deftest "comments nest"
  (is= '(:int :eof) (kinds "(* a (* b *) c *) 1")))

(deftest "an unterminated comment is an error"
  (signals diag:lex-error "unterminated comment" (lex:lex "(* forever")))

(deftest "string escapes"
  (is= (format nil "a~Ab~A\"\\A" #\Newline #\Tab)
       (first (texts "\"a\\nb\\t\\\"\\\\\\065\""))))

(deftest "a string is bytes"
  ;; Source text contributes its UTF-8; `\ddd` names one byte of it.
  (is= (first (texts "\"日\"")) (first (texts "\"\\230\\151\\165\"")))
  (is= 9 (length (first (texts "\"日本語\"")))))

(deftest "a numeric escape is three digits"
  (signals diag:lex-error "three digits" (lex:lex "\"\\65\"")))

(deftest "a string may not span lines"
  (signals diag:lex-error "may not span lines"
    (lex:lex (format nil "\"one~Atwo\"" #\Newline))))

(deftest "spans count from one"
  (let ((tokens (lex:lex (format nil "val~A  x" #\Newline))))
    (is= 1 (diag:span-line (lex:token-span (first tokens))))
    (is= 1 (diag:span-col (lex:token-span (first tokens))))
    (is= 2 (diag:span-line (lex:token-span (second tokens))))
    (is= 3 (diag:span-col (lex:token-span (second tokens))))))

(deftest "a number may not run into a name"
  (signals diag:lex-error "is not a number" (lex:lex "12ab")))

(deftest "a stray character is an error"
  (signals diag:lex-error "stray character" (lex:lex "a ? b")))

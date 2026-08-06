(ns wolv.lexer-test
  (:require [clojure.test :refer [deftest is testing]]
            [wolv.diag :as diag]
            [wolv.lexer :as lexer]))

(defn kinds [source] (mapv :kind (lexer/lex source)))

(defn raises?
  "Whether `thunk` raised a `kind` error whose message contains `substring`."
  [kind substring thunk]
  (try (thunk) false
       (catch clojure.lang.ExceptionInfo e
         (and (= kind (diag/wolv-error? e))
              (boolean (re-find (re-pattern (java.util.regex.Pattern/quote substring))
                                (.getMessage e)))))))

(deftest keywords-are-not-identifiers
  (is (= [:LET :VAL :EOF] (kinds "let val")))
  (is (= [:IDENT :EOF] (kinds "letter"))))

(deftest longest-punctuation-wins
  (is (= [:ASSIGN :COLON :LE :LT :NE :GE :EOF] (kinds ":= : <= < <> >="))))

(deftest comments-nest
  (is (= [:INT :EOF] (kinds "(* a (* b *) c *) 1")))
  (is (raises? :lex "unterminated comment" #(lexer/lex "(* forever"))))

(deftest string-escapes
  (is (= "a\nb\t\"\\A" (:text (first (lexer/lex "\"a\\nb\\t\\\"\\\\\\065\""))))))

(deftest a-string-is-bytes
  (testing "source text contributes its UTF-8; `\\ddd` names one byte of it"
    (is (= (:text (first (lexer/lex "\"日\"")))
           (:text (first (lexer/lex "\"\\230\\151\\165\"")))))
    (is (= 9 (count (:text (first (lexer/lex "\"日本語\""))))))))

(deftest bad-escapes
  (is (raises? :lex "three digits" #(lexer/lex "\"\\65\"")))
  (is (raises? :lex "may not span lines" #(lexer/lex "\"one\ntwo\""))))

(deftest spans-count-from-one
  (let [tokens (lexer/lex "val\n  x")]
    (is (= [1 1] [(:line (:at (first tokens))) (:col (:at (first tokens)))]))
    (is (= [2 3] [(:line (:at (second tokens))) (:col (:at (second tokens)))]))))

(deftest stray-input
  (is (raises? :lex "is not a number" #(lexer/lex "12ab")))
  (is (raises? :lex "stray character" #(lexer/lex "a ? b"))))

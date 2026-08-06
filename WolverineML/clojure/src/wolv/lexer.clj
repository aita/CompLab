(ns wolv.lexer
  "Tokens, and the hand-written scanner that produces them.

  A kind is a keyword, so the name a dump prints is the kind itself written
  down and there is no second table to keep in step with the first.
  `kind-text` is the other direction — what an error message calls a kind — and
  it is the only table here.

  The scanner is a map that a step answers with a new one of: `:pos` is how far
  it has read and `:line`/`:col` are where that is.  A Clojure string is code
  points, as Python's is, so it steps by characters and never counts UTF-8
  widths.  A string literal is the exception: `size`, `ord` and `substring`
  count bytes at run time, so a literal is built as bytes, one character per
  byte, which is what the dump and the emitter expect."
  (:require [clojure.string :as str]
            [wolv.diag :as diag]))

(def kind-text
  "What an error message calls each kind."
  {:INT "an integer" :STRING "a string" :IDENT "an identifier" :EOF "end of input"
   :AND "and" :ANDALSO "andalso" :BREAK "break" :DO "do" :ELSE "else" :END "end"
   :FALSE "false" :FOR "for" :FUN "fun" :IF "if" :IN "in" :LET "let" :MOD "mod"
   :NIL "nil" :ORELSE "orelse" :THEN "then" :TO "to" :TRUE "true" :TYPE "type"
   :VAL "val" :VAR "var" :WHILE "while"
   :LPAREN "(" :RPAREN ")" :LBRACK "[" :RBRACK "]" :LBRACE "{" :RBRACE "}"
   :COMMA "," :COLON ":" :SEMI ";" :DOT "." :ASSIGN ":=" :EQ "=" :NE "<>"
   :LE "<=" :LT "<" :GE ">=" :GT ">" :PLUS "+" :MINUS "-" :STAR "*" :SLASH "/"
   :CARET "^" :TILDE "~"})

(def keywords
  [:AND :ANDALSO :BREAK :DO :ELSE :END :FALSE :FOR :FUN :IF :IN :LET :MOD
   :NIL :ORELSE :THEN :TO :TRUE :TYPE :VAL :VAR :WHILE])

(def punctuation
  "Longest first, so that `:=` beats `:` and `<=` beats `<`."
  [:ASSIGN :NE :LE :GE
   :LPAREN :RPAREN :LBRACK :RBRACK :LBRACE :RBRACE :COMMA :COLON :SEMI :DOT
   :EQ :LT :GT :PLUS :MINUS :STAR :SLASH :CARET :TILDE])

(def escapes {\n \newline \t \tab \r \return \" \" \\ \\})

;; The letter and digit categories Python's `isalpha` and `isdigit` are.
(defn letter? [c] (Character/isLetter ^char c))
(defn digit? [c] (Character/isDigit ^char c))

;; -- the scanner -------------------------------------------------------------

(defn scanner [src] {:src src :pos 0 :line 1 :col 1})

(defn done? [s] (>= (:pos s) (count (:src s))))
(defn here [s] (.charAt ^String (:src s) (:pos s)))
(defn at [s] (diag/span (:line s) (:col s)))

(defn step [s]
  (if (= (here s) \newline)
    (assoc s :pos (inc (:pos s)) :line (inc (:line s)) :col 1)
    (assoc s :pos (inc (:pos s)) :col (inc (:col s)))))

(defn advance [s n] (nth (iterate step s) n))

(defn starts-with? [s prefix]
  (let [from (:pos s) to (+ from (count prefix))]
    (and (<= to (count (:src s)))
         (= (subs (:src s) from to) prefix))))

;; -- what is skipped ---------------------------------------------------------

;; Comments nest, so the depth is counted rather than the first `*)` taken.
(defn skip-comment [s]
  (let [start (at s)]
    (loop [s s depth 0]
      (cond
        (done? s) (diag/lex-error start "unterminated comment")
        (starts-with? s "(*") (recur (advance s 2) (inc depth))
        (starts-with? s "*)") (let [s (advance s 2)]
                                (if (> (dec depth) 0) (recur s (dec depth)) s))
        :else (recur (step s) depth)))))

(defn skip-trivia [s]
  (cond
    (done? s) s
    (contains? #{\space \tab \return \newline} (here s)) (skip-trivia (step s))
    (starts-with? s "(*") (skip-trivia (skip-comment s))
    :else s))

;; -- the pieces --------------------------------------------------------------

(defn token [kind text at] {:kind kind :text text :at at})

(defn scan-number [s start]
  (let [from (:pos s)
        s (loop [s s] (if (and (not (done? s)) (digit? (here s))) (recur (step s)) s))
        body (subs (:src s) from (:pos s))]
    (when (and (not (done? s)) (or (letter? (here s)) (= (here s) \_)))
      (diag/lex-error start (str "`" body (here s) "` is not a number")))
    [s (token :INT body start)]))

(defn continues-word? [c] (or (letter? c) (digit? c) (= c \_) (= c \')))

(defn scan-word [s start]
  (let [from (:pos s)
        s (loop [s s]
            (if (and (not (done? s)) (continues-word? (here s))) (recur (step s)) s))
        body (subs (:src s) from (:pos s))
        keyword* (first (filter #(= (kind-text %) body) keywords))]
    [s (token (or keyword* :IDENT) body start)]))

(defn scan-escape
  "What follows a backslash, as the one byte it names."
  [s]
  (when (done? s) (diag/lex-error (at s) "unterminated escape"))
  (let [c (here s)]
    (cond
      (digit? c)
      (let [src (:src s) from (:pos s)
            three (when (<= (+ from 3) (count src)) (subs src from (+ from 3)))
            digits (when (and three (every? #(<= (int \0) (int %) (int \9)) three))
                     (Long/parseLong three))]
        (if (and digits (< digits 256))
          [(advance s 3) (char digits)]
          (diag/lex-error (at s) "a numeric escape is three digits, `\\065`")))

      (and (< (int c) 128) (escapes c)) [(step s) (escapes c)]
      :else (diag/lex-error (at s) (str "unknown escape `\\" c "`")))))

;; A literal is a sequence of bytes: source text contributes its UTF-8 encoding,
;; and `\ddd` names one byte.  Each byte becomes one character of the result, so
;; the count is the length the run time will measure.
(defn scan-string [s start]
  (loop [s (step s) out (StringBuilder.)]
    (if (done? s)
      (diag/lex-error start "unterminated string")
      (let [c (here s)]
        (cond
          (= c \") [(step s) (token :STRING (.toString out) start)]
          (= c \newline) (diag/lex-error (at s) "a string may not span lines")
          (= c \\) (let [[s ch] (scan-escape (step s))] (recur s (.append out ch)))
          :else (do (doseq [b (.getBytes (str c) "UTF-8")]
                      (.append out (char (bit-and b 0xFF))))
                    (recur (step s) out)))))))

(defn next-token [s]
  (let [s (skip-trivia s)
        start (at s)]
    (cond
      (done? s) [s (token :EOF "" start)]
      (digit? (here s)) (scan-number s start)
      (or (letter? (here s)) (= (here s) \_)) (scan-word s start)
      (= (here s) \") (scan-string s start)
      :else
      (let [kind (first (filter #(starts-with? s (kind-text %)) punctuation))]
        (when-not kind
          (diag/lex-error start (str "stray character `" (here s) "`")))
        (let [text (kind-text kind)]
          [(advance s (count text)) (token kind text start)])))))

(defn lex
  "Source text into tokens, in one pass, no regexes."
  [source]
  (loop [s (scanner source) acc []]
    (let [[s t] (next-token s)]
      (if (= (:kind t) :EOF)
        (conj acc t)
        (recur s (conj acc t))))))

(defn dump [tokens]
  (str/join "\n"
            (map (fn [t]
                   (str (diag/show-span (:at t)) "\t" (name (:kind t)) "\t" (:text t)))
                 tokens)))

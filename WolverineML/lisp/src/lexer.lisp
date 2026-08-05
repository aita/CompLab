;;;; Tokens, and the hand-written scanner that produces them.
;;;;
;;;; A token kind is a keyword symbol, so the scanner needs no enumeration
;;;; type: `:while` is the kind, `:let` is the kind, and the two tables below
;;;; say how each one is written in a dump and what an error message calls it.

(defpackage #:wolv.lexer
  (:use #:cl)
  (:local-nicknames (#:diag #:wolv.diag))
  (:export #:token #:make-token #:token-p
           #:token-kind #:token-text #:token-span #:token-description
           #:kind-name #:kind-text #:lex #:utf-8-bytes))

(in-package #:wolv.lexer)

;; Each kind, the name a dump gives it, and what an error message calls it.
(defparameter *kinds*
  '((:int      "INT"      "an integer")
    (:string   "STRING"   "a string")
    (:ident    "IDENT"    "an identifier")
    (:eof      "EOF"      "end of input")
    (:and      "AND"      "and")
    (:andalso  "ANDALSO"  "andalso")
    (:break    "BREAK"    "break")
    (:do       "DO"       "do")
    (:else     "ELSE"     "else")
    (:end      "END"      "end")
    (:false    "FALSE"    "false")
    (:for      "FOR"      "for")
    (:fun      "FUN"      "fun")
    (:if       "IF"       "if")
    (:in       "IN"       "in")
    (:let      "LET"      "let")
    (:mod      "MOD"      "mod")
    (:nil      "NIL"      "nil")
    (:orelse   "ORELSE"   "orelse")
    (:then     "THEN"     "then")
    (:to       "TO"       "to")
    (:true     "TRUE"     "true")
    (:type     "TYPE"     "type")
    (:val      "VAL"      "val")
    (:var      "VAR"      "var")
    (:while    "WHILE"    "while")
    (:lparen   "LPAREN"   "(")
    (:rparen   "RPAREN"   ")")
    (:lbrack   "LBRACK"   "[")
    (:rbrack   "RBRACK"   "]")
    (:lbrace   "LBRACE"   "{")
    (:rbrace   "RBRACE"   "}")
    (:comma    "COMMA"    ",")
    (:colon    "COLON"    ":")
    (:semi     "SEMI"     ";")
    (:dot      "DOT"      ".")
    (:assign   "ASSIGN"   ":=")
    (:eq       "EQ"       "=")
    (:ne       "NE"       "<>")
    (:le       "LE"       "<=")
    (:lt       "LT"       "<")
    (:ge       "GE"       ">=")
    (:gt       "GT"       ">")
    (:plus     "PLUS"     "+")
    (:minus    "MINUS"    "-")
    (:star     "STAR"     "*")
    (:slash    "SLASH"    "/")
    (:caret    "CARET"    "^")
    (:tilde    "TILDE"    "~")))

(defun kind-name (kind) (second (assoc kind *kinds*)))
(defun kind-text (kind) (third (assoc kind *kinds*)))

(defparameter *keywords*
  (loop for (kind nil text) in *kinds*
        unless (member kind '(:int :string :ident :eof))
          when (every #'alpha-char-p text)
            collect (cons text kind))
  "The words that are not identifiers.")

(defparameter *punctuation*
  ;; Longest first, so that `:=` beats `:` and `<=` beats `<`.
  (stable-sort
   (loop for (kind nil text) in *kinds*
         unless (or (member kind '(:int :string :ident :eof))
                    (alpha-char-p (char text 0)))
           collect (cons text kind))
   #'> :key (lambda (pair) (length (car pair)))))

(defparameter *escapes*
  '((#\n . #\Newline) (#\t . #\Tab) (#\r . #\Return)
    (#\" . #\") (#\\ . #\\)))

(defstruct (token (:constructor make-token (kind text span)) (:copier nil))
  kind text span)

(defun token-description (tok)
  "The token as an error message names it."
  (case (token-kind tok)
    (:eof "end of input")
    (:string (format nil "\"~A\"" (token-text tok)))
    (t (format nil "`~A`" (token-text tok)))))

;; -- one byte at a time -------------------------------------------------------

(defun utf-8-bytes (ch)
  "The UTF-8 of one character, which is what a literal contributes."
  (let ((n (char-code ch)))
    (cond ((< n #x80) (list n))
          ((< n #x800)
           (list (logior #xC0 (ash n -6)) (logior #x80 (logand n #x3F))))
          ((< n #x10000)
           (list (logior #xE0 (ash n -12))
                 (logior #x80 (logand (ash n -6) #x3F))
                 (logior #x80 (logand n #x3F))))
          (t
           (list (logior #xF0 (ash n -18))
                 (logior #x80 (logand (ash n -12) #x3F))
                 (logior #x80 (logand (ash n -6) #x3F))
                 (logior #x80 (logand n #x3F)))))))

;; -- the scanner --------------------------------------------------------------

(defclass lexer ()
  ((src :initarg :src :reader src)
   (pos :initform 0 :accessor pos)
   (line :initform 1 :accessor line)
   (col :initform 1 :accessor col)))

(defun at-end-p (lx) (>= (pos lx) (length (src lx))))
(defun here (lx) (char (src lx) (pos lx)))

(defun looking-at (lx text)
  (let ((end (+ (pos lx) (length text))))
    (and (<= end (length (src lx)))
         (string= text (src lx) :start2 (pos lx) :end2 end))))

(defun advance (lx n)
  (dotimes (i n)
    (if (char= (here lx) #\Newline)
        (setf (line lx) (1+ (line lx)) (col lx) 1)
        (incf (col lx)))
    (incf (pos lx))))

(defun current-span (lx) (diag:span (line lx) (col lx)))

(defun ascii-digit-p (ch) (char<= #\0 ch #\9))

(defun word-char-p (ch)
  (or (alphanumericp ch) (char= ch #\_) (char= ch #\')))

(defun skip-trivia (lx)
  (loop until (at-end-p lx)
        do (let ((ch (here lx)))
             (cond ((member ch '(#\Space #\Tab #\Return #\Newline)) (advance lx 1))
                   ((looking-at lx "(*") (skip-comment lx))
                   (t (return))))))

(defun skip-comment (lx)
  (let ((span (current-span lx))
        (depth 0))
    (loop until (at-end-p lx)
          do (cond ((looking-at lx "(*") (incf depth) (advance lx 2))
                   ((looking-at lx "*)")
                    (decf depth) (advance lx 2)
                    (when (zerop depth) (return-from skip-comment)))
                   (t (advance lx 1))))
    (error 'diag:lex-error :span span :message "unterminated comment")))

(defun scan-number (lx span)
  (let ((start (pos lx)))
    (loop until (at-end-p lx) while (ascii-digit-p (here lx)) do (advance lx 1))
    (let ((text (subseq (src lx) start (pos lx))))
      (when (and (not (at-end-p lx))
                 (or (alpha-char-p (here lx)) (char= (here lx) #\_)))
        (error 'diag:lex-error :span span
                               :message (format nil "`~A~A` is not a number"
                                                text (here lx))))
      (make-token :int text span))))

(defun scan-word (lx span)
  (let ((start (pos lx)))
    (loop until (at-end-p lx) while (word-char-p (here lx)) do (advance lx 1))
    (let* ((text (subseq (src lx) start (pos lx)))
           (keyword (cdr (assoc text *keywords* :test #'string=))))
      (make-token (or keyword :ident) text span))))

(defun scan-string (lx span)
  "A string literal is a sequence of bytes.

`size`, `ord` and `substring` count bytes at run time, so a literal is read as
bytes here too: source text contributes its UTF-8 encoding, and `\\ddd` names
one byte.  Each byte is kept as one character, which is what `emit:escape`
writes back out."
  (advance lx 1)
  (let ((out (make-string-output-stream)))
    (loop
      (when (at-end-p lx)
        (error 'diag:lex-error :span span :message "unterminated string"))
      (let ((ch (here lx)))
        (cond
          ((char= ch #\")
           (advance lx 1)
           (return (make-token :string (get-output-stream-string out) span)))
          ((char= ch #\Newline)
           (error 'diag:lex-error :span (current-span lx)
                                  :message "a string may not span lines"))
          ((char= ch #\\)
           (advance lx 1)
           (write-char (scan-escape lx) out))
          (t
           (advance lx 1)
           (if (< (char-code ch) 128)
               (write-char ch out)
               (dolist (byte (utf-8-bytes ch)) (write-char (code-char byte) out)))))))))

(defun scan-escape (lx)
  (when (at-end-p lx)
    (error 'diag:lex-error :span (current-span lx) :message "unterminated escape"))
  (let ((ch (here lx)))
    (cond
      ((ascii-digit-p ch)
       (let ((digits (subseq (src lx) (pos lx) (min (length (src lx)) (+ (pos lx) 3)))))
         (unless (and (= (length digits) 3)
                      (every #'ascii-digit-p digits)
                      (< (parse-integer digits) 256))
           (error 'diag:lex-error :span (current-span lx)
                                  :message "a numeric escape is three digits, `\\065`"))
         (advance lx 3)
         (code-char (parse-integer digits))))
      ((assoc ch *escapes*) (advance lx 1) (cdr (assoc ch *escapes*)))
      (t (error 'diag:lex-error :span (current-span lx)
                                :message (format nil "unknown escape `\\~A`" ch))))))

(defun next-token (lx)
  (skip-trivia lx)
  (let ((span (current-span lx)))
    (when (at-end-p lx)
      (return-from next-token (make-token :eof "" span)))
    (let ((ch (here lx)))
      (cond
        ((ascii-digit-p ch) (scan-number lx span))
        ((or (alpha-char-p ch) (char= ch #\_)) (scan-word lx span))
        ((char= ch #\") (scan-string lx span))
        (t
         (loop for (text . kind) in *punctuation*
               when (looking-at lx text)
                 do (advance lx (length text))
                    (return (make-token kind text span))
               finally (error 'diag:lex-error
                              :span span
                              :message (format nil "stray character `~A`" ch))))))))

(defun lex (source)
  "SOURCE into a list of tokens, in one pass, no regular expressions."
  (let ((lx (make-instance 'lexer :src source)))
    (loop for tok = (next-token lx)
          collect tok
          until (eq (token-kind tok) :eof))))

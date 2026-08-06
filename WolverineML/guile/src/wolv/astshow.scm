;;; An indented dump of the typed syntax tree, for `wolv emit -s ast`.
;;;
;;; One method per node, and `put` is how a method writes its line: the walk is
;;; the dispatch, so nothing here lists the node kinds a second time.

(define-module (wolv astshow)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (wolv types)
  #:use-module (wolv ast)
  #:export (show-program quoted))

;; A string literal, written the way the Python tree writes it, so that a dump
;; taken from either is the same dump.  Every character of one is a byte, and a
;; byte that stands for nothing printable is shown as `\xNN`.
;;
;; The other ports ask a Unicode database which bytes those are.  Over the range
;; a literal can hold — U+0000 to U+00FF — the answer is four fixed ranges: the
;; C0 and C1 controls, no-break space, and the soft hyphen.
(define (quoted text)
  (let ((quote-char (if (and (string-index text #\') (not (string-index text #\")))
                        #\" #\'))
        (out (open-output-string)))
    (write-char quote-char out)
    (string-for-each
     (lambda (c)
       (let ((n (char->integer c)))
         (cond
          ((or (char=? c quote-char) (char=? c #\\))
           (write-char #\\ out) (write-char c out))
          ((= n 10) (display "\\n" out))
          ((= n 13) (display "\\r" out))
          ((= n 9) (display "\\t" out))
          ((or (<= n #x1F) (and (<= #x7F n) (<= n #xA0)) (= n #xAD))
           (display (format #f "\\x~a" (two-digit-hex n)) out))
          (else (write-char c out)))))
     text)
    (write-char quote-char out)
    (get-output-string out)))

(define (two-digit-hex n)
  (let ((s (number->string n 16)))
    (if (< (string-length s) 2) (string-append "0" s) s)))

(define (escapes sym)
  (if (and sym (is-a? sym <var-sym>) (var-sym-escapes? sym)) " (escapes)" ""))

(define (show-type e)
  (if (exp-ty e) (string-append " : " (show-ty (exp-ty e))) ""))

;; -- the walk ----------------------------------------------------------------

(define-generic show-decl)
(define-generic show-exp)

(define (kids depth put . es)
  (for-each (lambda (k) (show-exp k (+ depth 1) put)) es))

(define-method (show-decl (d <d-type>) depth put)
  (for-each (lambda (b) (put depth (string-append "type " (type-bind-name b))))
            (d-type-binds d)))

(define-method (show-decl (d <d-val>) depth put)
  (put depth (string-append (if (d-val-var? d) "var" "val") " "
                            (or (d-val-name d) "()") (escapes (d-val-sym d))))
  (show-exp (d-val-init d) (+ depth 1) put))

(define-method (show-decl (d <d-fun>) depth put)
  (for-each
   (lambda (b)
     (let ((params (string-join
                    (map (lambda (p)
                           (string-append (param-name p) (escapes (param-sym p))))
                         (fun-bind-params b))
                    ", "))
           (result (if (fun-bind-sym b)
                       (show-ty (fun-sym-result (fun-bind-sym b)))
                       "?")))
       (put depth (format #f "fun ~a(~a) : ~a" (fun-bind-label b) params result))
       (show-exp (fun-bind-body b) (+ depth 1) put)))
   (d-fun-binds d)))

(define-method (show-exp (e <e-int>) depth put)
  (put depth (format #f "int ~a" (e-int-value e))))
(define-method (show-exp (e <e-str>) depth put)
  (put depth (string-append "string " (quoted (e-str-value e)))))
(define-method (show-exp (e <e-bool>) depth put)
  (put depth (string-append "bool " (if (e-bool-value e) "true" "false"))))
(define-method (show-exp (e <e-nil>) depth put) (put depth "nil"))
(define-method (show-exp (e <e-unit>) depth put) (put depth "()"))
(define-method (show-exp (e <e-var>) depth put)
  (put depth (string-append "var " (e-var-name e) (show-type e))))

(define-method (show-exp (e <e-call>) depth put)
  (put depth (string-append "call " (e-call-callee e) (show-type e)))
  (for-each (lambda (a) (show-exp a (+ depth 1) put)) (e-call-args e)))

(define-method (show-exp (e <e-record>) depth put)
  (put depth (string-append "record " (e-record-tyname e) (show-type e)))
  (for-each (lambda (f)
              (put (+ depth 1) (string-append (field-init-name f) " ="))
              (show-exp (field-init-value f) (+ depth 2) put))
            (e-record-inits e)))

(define-method (show-exp (e <e-index>) depth put)
  (put depth (string-append "index" (show-type e)))
  (kids depth put (e-index-array e) (e-index-index e)))

(define-method (show-exp (e <e-field>) depth put)
  (put depth (string-append "field ." (e-field-select e) (show-type e)))
  (kids depth put (e-field-record e)))

(define-method (show-exp (e <e-neg>) depth put)
  (put depth "neg")
  (kids depth put (e-neg-operand e)))

(define-method (show-exp (e <e-binary>) depth put)
  (put depth (string-append (binary-op e) (show-type e)))
  (kids depth put (binary-lhs e) (binary-rhs e)))

(define-method (show-exp (e <e-assign>) depth put)
  (put depth ":=")
  (kids depth put (e-assign-target e) (e-assign-value e)))

(define-method (show-exp (e <e-if>) depth put)
  (put depth (string-append "if" (show-type e)))
  (kids depth put (e-if-test e) (e-if-then e))
  (when (e-if-else e) (show-exp (e-if-else e) (+ depth 1) put)))

(define-method (show-exp (e <e-while>) depth put)
  (put depth "while")
  (kids depth put (e-while-test e) (e-while-body e)))

(define-method (show-exp (e <e-for>) depth put)
  (put depth (string-append "for " (e-for-binder e) (escapes (exp-sym e))))
  (kids depth put (e-for-lo e) (e-for-hi e) (e-for-body e)))

(define-method (show-exp (e <e-break>) depth put) (put depth "break"))

(define-method (show-exp (e <e-seq>) depth put)
  (put depth (string-append "seq" (show-type e)))
  (for-each (lambda (item) (show-exp item (+ depth 1) put)) (e-seq-items e)))

(define-method (show-exp (e <e-let>) depth put)
  (put depth (string-append "let" (show-type e)))
  (for-each (lambda (d) (show-decl d (+ depth 1) put)) (e-let-decls e))
  (put depth "in")
  (show-exp (e-let-body e) (+ depth 1) put))

(define (show-program prog)
  (let ((lines '()))
    (define (put depth text)
      (set! lines (cons (string-append (make-string (* 2 depth) #\space) text) lines)))
    (for-each (lambda (d) (show-decl d 0 put)) prog)
    (string-append (string-join (reverse lines) "\n") "\n")))

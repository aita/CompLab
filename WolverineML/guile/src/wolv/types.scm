;;; Semantic types, and the symbols that carry them.
;;;
;;; Types are monomorphic.  Records are nominal — two record types with the same
;;; fields are different types — and everything else is structural, which for
;;; this language means arrays compare by their element type.
;;;
;;; The four ground types are Scheme symbols, because that is all they are: a
;;; name with nothing inside.  The two that carry something are objects, and a
;;; record is compared by identity, which `eq?` on the object gives directly.

(define-module (wolv types)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:export (<ty-record> ty-record ty-record-name ty-record-fields set-ty-record-fields!
            <ty-array> ty-array ty-array-elem
            same? compatible? show-ty record-index record-field-type
            <var-sym> var-sym var-sym-name var-sym-ty var-sym-mutable? var-sym-depth
            var-sym-escapes? set-var-sym-escapes?! var-sym-home set-var-sym-home!
            <fun-sym> fun-sym fun-sym-name fun-sym-label fun-sym-params
            fun-sym-result fun-sym-depth fun-sym-builtin
            <home> <in-register> in-register in-register-reg
            <in-frame> in-frame in-frame-slot))

;; The fields are mutable, and the record is built empty first, because a record
;; may name itself: `type list = {head: int, tail: list}` needs `list` to exist
;; before its fields can be typed.
(define-class <ty-record> ()
  (name #:init-keyword #:name #:getter ty-record-name)
  (fields #:init-keyword #:fields #:accessor ty-record-fields))

(define-class <ty-array> ()
  (elem #:init-keyword #:elem #:getter ty-array-elem))

(define (ty-record name fields) (make <ty-record> #:name name #:fields fields))
(define (ty-array elem) (make <ty-array> #:elem elem))

(define (set-ty-record-fields! r fields) (set! (ty-record-fields r) fields))

;; Type equality: nominal for records, structural for arrays.
(define (same? a b)
  (cond
   ((and (is-a? a <ty-record>) (is-a? b <ty-record>)) (eq? a b))
   ((and (is-a? a <ty-array>) (is-a? b <ty-array>))
    (same? (ty-array-elem a) (ty-array-elem b)))
   ((or (is-a? a <ty-record>) (is-a? b <ty-record>)
        (is-a? a <ty-array>) (is-a? b <ty-array>)) #f)
   (else (eq? a b))))

;; Equality, but `nil` stands in for any record.
(define (compatible? a b)
  (cond
   ((and (eq? a 'nil) (or (is-a? b <ty-record>) (eq? b 'nil))) #t)
   ((and (or (is-a? a <ty-record>) (eq? a 'nil)) (eq? b 'nil)) #t)
   (else (same? a b))))

(define (show-ty t)
  (cond
   ((is-a? t <ty-record>) (ty-record-name t))
   ((is-a? t <ty-array>) (string-append (show-ty (ty-array-elem t)) " array"))
   (else (symbol->string t))))

(define (record-index r name)
  (or (list-index (lambda (f) (string=? (car f) name)) (ty-record-fields r)) -1))

(define (record-field-type r name)
  (let ((found (assoc name (ty-record-fields r))))
    (and found (cdr found))))

;; -- where a variable lives --------------------------------------------------

;; Once lowering has decided.  Two classes and not a slot number beside a
;; register number beside a flag: a frame slot may be negative — that is an
;; argument the caller left on the stack — so no number is free to mean "not
;; decided yet".
(define-class <home> ())

(define-class <in-register> (<home>)
  (reg #:init-keyword #:reg #:getter in-register-reg))

(define-class <in-frame> (<home>)
  (slot #:init-keyword #:slot #:getter in-frame-slot))

(define (in-register reg) (make <in-register> #:reg reg))
(define (in-frame slot) (make <in-frame> #:slot slot))

;; -- the symbols -------------------------------------------------------------

;; `depth` is the static nesting depth of the function that binds it.  A
;; variable read from a deeper function escapes, and then it lives in a frame
;; slot instead of a register.
(define-class <var-sym> ()
  (name #:init-keyword #:name #:getter var-sym-name)
  (ty #:init-keyword #:ty #:getter var-sym-ty)
  (mutable? #:init-keyword #:mutable? #:getter var-sym-mutable?)
  (depth #:init-keyword #:depth #:getter var-sym-depth)
  (escapes? #:init-value #f #:accessor var-sym-escapes?)
  (home #:init-value #f #:accessor var-sym-home))

(define (var-sym name ty mutable? depth)
  (make <var-sym> #:name name #:ty ty #:mutable? mutable? #:depth depth))

(define (set-var-sym-escapes?! sym value) (set! (var-sym-escapes? sym) value))
(define (set-var-sym-home! sym value) (set! (var-sym-home sym) value))

;; A function.  Functions are not values, so there is no function type.
;; `builtin` is #f unless it is one of the prelude's.
(define-class <fun-sym> ()
  (name #:init-keyword #:name #:getter fun-sym-name)
  (label #:init-keyword #:label #:getter fun-sym-label)
  (params #:init-keyword #:params #:getter fun-sym-params)
  (result #:init-keyword #:result #:getter fun-sym-result)
  (depth #:init-keyword #:depth #:getter fun-sym-depth)
  (builtin #:init-keyword #:builtin #:getter fun-sym-builtin))

(define (fun-sym name label params result depth builtin)
  (make <fun-sym> #:name name #:label label #:params params
        #:result result #:depth depth #:builtin builtin))

#lang racket/base

;; Semantic types, and the symbols that carry them.
;;
;; Types are monomorphic.  Records are nominal — two record types with the same
;; fields are different types — and everything else is structural, which for this
;; language means arrays compare by their element type.
;;
;; The four ground types are symbols, because that is all they are: a name with
;; nothing inside.  The two that carry something are structs, and a record is
;; compared by identity, which `eq?` on the struct gives directly.

(require racket/list)

(provide (struct-out ty:record) (struct-out ty:array)
         same? compatible? show-ty
         (struct-out var-sym) (struct-out fun-sym)
         (struct-out in-register) (struct-out in-frame)
         record-index record-field-type)

;; Mutable, and built empty first, because a record may name itself:
;; `type list = {head: int, tail: list}` needs `list` to exist before its fields
;; can be typed.
(struct ty:record (name [fields #:mutable]) #:transparent)
(struct ty:array (elem) #:transparent)

;; Type equality: nominal for records, structural for arrays.
(define (same? a b)
  (cond
    [(and (ty:record? a) (ty:record? b)) (eq? a b)]
    [(and (ty:array? a) (ty:array? b)) (same? (ty:array-elem a) (ty:array-elem b))]
    [(or (ty:record? a) (ty:record? b) (ty:array? a) (ty:array? b)) #f]
    [else (eq? a b)]))

;; Equality, but `nil` stands in for any record.
(define (compatible? a b)
  (cond
    [(and (eq? a 'nil) (or (ty:record? b) (eq? b 'nil))) #t]
    [(and (or (ty:record? a) (eq? a 'nil)) (eq? b 'nil)) #t]
    [else (same? a b)]))

(define (show-ty t)
  (cond
    [(ty:record? t) (ty:record-name t)]
    [(ty:array? t) (string-append (show-ty (ty:array-elem t)) " array")]
    [else (symbol->string t)]))

(define (record-index r name)
  (or (index-where (ty:record-fields r) (λ (f) (string=? (car f) name))) -1))

(define (record-field-type r name)
  (define found (assoc name (ty:record-fields r)))
  (and found (cdr found)))

;; -- symbols -----------------------------------------------------------------

;; Where a variable lives, once lowering has decided.  Two values and not a slot
;; number beside a register number beside a flag: a frame slot may be negative —
;; that is an argument the caller left on the stack — so no number is free to
;; mean "not decided yet".
(struct in-register (reg) #:transparent)
(struct in-frame (slot) #:transparent)

;; `depth` is the static nesting depth of the function that binds it.  A variable
;; read from a deeper function escapes, and then it lives in a frame slot instead
;; of a register.
(struct var-sym (name ty mutable? depth [escapes? #:mutable] [home #:mutable])
  #:transparent)

;; A function.  Functions are not values, so there is no function type.
;; `builtin` is #f unless it is one of the prelude's.
(struct fun-sym (name label params result depth builtin) #:transparent)

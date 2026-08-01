#lang racket/base

;; The syntax tree.
;;
;; Every expression is a span, the node itself, and the three things the checker
;; writes in — the type, what a name resolved to, and which word of a record a
;; field access reads.  Saying them once on the wrapper rather than in twenty
;; constructors is what keeps the node structs to their own business.
;;
;; The node names carry an `e:` and the declarations a `d:`, because `if`, `let`
;; and `while` are Racket's and a struct of that name would shadow them here.
;; Modules that need both this and the IR bring one in under a prefix.

(provide (struct-out exp) make-exp
         (struct-out e:int) (struct-out e:str) (struct-out e:bool)
         (struct-out e:nil) (struct-out e:unit)
         (struct-out e:var) (struct-out e:call) (struct-out e:record)
         (struct-out e:index) (struct-out e:field) (struct-out e:neg)
         (struct-out e:bin) (struct-out e:logic) (struct-out e:assign)
         (struct-out e:if) (struct-out e:while) (struct-out e:for)
         (struct-out e:break) (struct-out e:seq) (struct-out e:let)
         (struct-out field-init)
         (struct-out t:name) (struct-out t:array) (struct-out t:record)
         (struct-out ty-field)
         (struct-out d:type) (struct-out d:val) (struct-out d:fun)
         (struct-out type-bind) (struct-out param) (struct-out fun-bind)
         ty-at decl-at)

;; -- types as they are written -----------------------------------------------

(struct t:name (at name) #:transparent)
(struct t:array (at elem) #:transparent)
(struct t:record (at fields) #:transparent)

(struct ty-field (name ty at) #:transparent)

(define (ty-at t)
  (cond [(t:name? t) (t:name-at t)]
        [(t:array? t) (t:array-at t)]
        [(t:record? t) (t:record-at t)]))

;; -- expressions -------------------------------------------------------------

(struct exp (at node [ty #:mutable] [sym #:mutable] [offset #:mutable]) #:transparent)

;; What the parser always wants: a node with its span and nothing known yet.
(define (make-exp at node) (exp at node #f #f -1))

(struct e:int (value) #:transparent)
(struct e:str (value) #:transparent)
(struct e:bool (value) #:transparent)
(struct e:nil () #:transparent)
(struct e:unit () #:transparent)
(struct e:var (name) #:transparent)
(struct e:call (callee args) #:transparent)

;; `inits` is put into declaration order by the checker, so it is the one node
;; field that changes after the parser built it.
(struct e:record (tyname [inits #:mutable]) #:transparent)

(struct e:index (array index) #:transparent)
(struct e:field (record select) #:transparent)
(struct e:neg (operand) #:transparent)
(struct e:bin (op lhs rhs) #:transparent)

;; `andalso` and `orelse`, which are control flow and not operators.
(struct e:logic (op lhs rhs) #:transparent)

(struct e:assign (target value) #:transparent)
(struct e:if (cond then els) #:transparent)
(struct e:while (cond body) #:transparent)
(struct e:for (binder lo hi body) #:transparent)
(struct e:break () #:transparent)
(struct e:seq (items) #:transparent)
(struct e:let (decls body) #:transparent)

(struct field-init (name value at) #:transparent)

;; -- declarations ------------------------------------------------------------

(struct d:type (at binds) #:transparent)
(struct d:val (at name written init var? [sym #:mutable]) #:transparent)
(struct d:fun (at binds) #:transparent)

(struct type-bind (name bound at) #:transparent)
(struct param (name ty at [sym #:mutable]) #:transparent)
(struct fun-bind (label params result body at [sym #:mutable]) #:transparent)

(define (decl-at d)
  (cond [(d:type? d) (d:type-at d)]
        [(d:val? d) (d:val-at d)]
        [(d:fun? d) (d:fun-at d)]))

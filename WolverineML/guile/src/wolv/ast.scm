;;; The syntax tree, as a class hierarchy.
;;;
;;; Every node is a class, and the three things the checker writes in — the
;;; type, what a name resolved to, and which word of a record a field access
;;; reads — are slots of `<exp>`, which every expression inherits.  Saying them
;;; once on the base class rather than in twenty constructors is what keeps the
;;; nodes to their own business, and inheritance is what lets a node be the
;;; thing that carries them rather than something inside a wrapper.
;;;
;;; The passes below dispatch on these classes: `astshow`, `typecheck` and
;;; `lower` are each a set of methods, one per node, and adding a form to the
;;; language means adding a class and the methods that answer for it.

(define-module (wolv ast)
  #:use-module (oop goops)
  #:export (<node> node-at
            <exp> exp-ty set-exp-ty! exp-sym set-exp-sym! exp-offset set-exp-offset!
            <e-int> e-int e-int-value
            <e-str> e-str e-str-value
            <e-bool> e-bool e-bool-value
            <e-nil> e-nil
            <e-unit> e-unit
            <e-var> e-var e-var-name
            <e-call> e-call e-call-callee e-call-args
            <e-record> e-record e-record-tyname e-record-inits set-e-record-inits!
            <e-index> e-index e-index-array e-index-index
            <e-field> e-field e-field-record e-field-select
            <e-neg> e-neg e-neg-operand
            <e-binary> binary-op binary-lhs binary-rhs
            <e-bin> e-bin <e-logic> e-logic
            <e-assign> e-assign e-assign-target e-assign-value
            <e-if> e-if e-if-test e-if-then e-if-else
            <e-while> e-while e-while-test e-while-body
            <e-for> e-for e-for-binder e-for-lo e-for-hi e-for-body
            <e-break> e-break
            <e-seq> e-seq e-seq-items
            <e-let> e-let e-let-decls e-let-body
            <field-init> field-init field-init-name field-init-value field-init-at
            <ty-exp>
            <t-name> t-name t-name-name
            <t-array> t-array t-array-elem
            <t-record> t-record t-record-fields
            <ty-field> ty-field ty-field-name ty-field-ty ty-field-at
            <decl>
            <d-type> d-type d-type-binds
            <d-val> d-val d-val-name d-val-written d-val-init d-val-var? d-val-sym
            set-d-val-sym!
            <d-fun> d-fun d-fun-binds
            <type-bind> type-bind type-bind-name type-bind-bound type-bind-at
            <param> param param-name param-ty param-at param-sym set-param-sym!
            <fun-bind> fun-bind fun-bind-label fun-bind-params fun-bind-result
            fun-bind-body fun-bind-at fun-bind-sym set-fun-bind-sym!))

;; Everything the parser builds knows where it came from.
(define-class <node> ()
  (at #:init-keyword #:at #:getter node-at))

;; -- types as they are written -----------------------------------------------

(define-class <ty-exp> (<node>))

(define-class <t-name> (<ty-exp>)
  (name #:init-keyword #:name #:getter t-name-name))

(define-class <t-array> (<ty-exp>)
  (elem #:init-keyword #:elem #:getter t-array-elem))

(define-class <t-record> (<ty-exp>)
  (fields #:init-keyword #:fields #:getter t-record-fields))

(define (t-name at name) (make <t-name> #:at at #:name name))
(define (t-array at elem) (make <t-array> #:at at #:elem elem))
(define (t-record at fields) (make <t-record> #:at at #:fields fields))

(define-class <ty-field> (<node>)
  (name #:init-keyword #:name #:getter ty-field-name)
  (ty #:init-keyword #:ty #:getter ty-field-ty))

(define (ty-field name ty at) (make <ty-field> #:name name #:ty ty #:at at))
(define (ty-field-at f) (node-at f))

;; -- expressions -------------------------------------------------------------

(define-class <exp> (<node>)
  (ty #:init-value #f #:accessor exp-ty)
  (sym #:init-value #f #:accessor exp-sym)
  (offset #:init-value -1 #:accessor exp-offset))

(define (set-exp-ty! e v) (set! (exp-ty e) v))
(define (set-exp-sym! e v) (set! (exp-sym e) v))
(define (set-exp-offset! e v) (set! (exp-offset e) v))

(define-class <e-int> (<exp>)
  (value #:init-keyword #:value #:getter e-int-value))
(define-class <e-str> (<exp>)
  (value #:init-keyword #:value #:getter e-str-value))
(define-class <e-bool> (<exp>)
  (value #:init-keyword #:value #:getter e-bool-value))
(define-class <e-nil> (<exp>))
(define-class <e-unit> (<exp>))
(define-class <e-var> (<exp>)
  (name #:init-keyword #:name #:getter e-var-name))
(define-class <e-call> (<exp>)
  (callee #:init-keyword #:callee #:getter e-call-callee)
  (args #:init-keyword #:args #:getter e-call-args))

;; `inits` is put into declaration order by the checker, so it is the one node
;; slot that changes after the parser filled it.
(define-class <e-record> (<exp>)
  (tyname #:init-keyword #:tyname #:getter e-record-tyname)
  (inits #:init-keyword #:inits #:accessor e-record-inits))

(define-class <e-index> (<exp>)
  (array #:init-keyword #:array #:getter e-index-array)
  (index #:init-keyword #:index #:getter e-index-index))
(define-class <e-field> (<exp>)
  (record #:init-keyword #:record #:getter e-field-record)
  (select #:init-keyword #:select #:getter e-field-select))
(define-class <e-neg> (<exp>)
  (operand #:init-keyword #:operand #:getter e-neg-operand))

;; An operator and its two sides.  `andalso` and `orelse` are control flow and
;; not operators, so they are a class of their own — but they are written and
;; printed the same way, which is what the shared base is for.
(define-class <e-binary> (<exp>)
  (op #:init-keyword #:op #:getter binary-op)
  (lhs #:init-keyword #:lhs #:getter binary-lhs)
  (rhs #:init-keyword #:rhs #:getter binary-rhs))

(define-class <e-bin> (<e-binary>))
(define-class <e-logic> (<e-binary>))

(define-class <e-assign> (<exp>)
  (target #:init-keyword #:target #:getter e-assign-target)
  (value #:init-keyword #:value #:getter e-assign-value))
(define-class <e-if> (<exp>)
  (test #:init-keyword #:test #:getter e-if-test)
  (then #:init-keyword #:then #:getter e-if-then)
  (els #:init-keyword #:els #:getter e-if-else))
(define-class <e-while> (<exp>)
  (test #:init-keyword #:test #:getter e-while-test)
  (body #:init-keyword #:body #:getter e-while-body))
(define-class <e-for> (<exp>)
  (binder #:init-keyword #:binder #:getter e-for-binder)
  (lo #:init-keyword #:lo #:getter e-for-lo)
  (hi #:init-keyword #:hi #:getter e-for-hi)
  (body #:init-keyword #:body #:getter e-for-body))
(define-class <e-break> (<exp>))
(define-class <e-seq> (<exp>)
  (items #:init-keyword #:items #:getter e-seq-items))
(define-class <e-let> (<exp>)
  (decls #:init-keyword #:decls #:getter e-let-decls)
  (body #:init-keyword #:body #:getter e-let-body))

(define (e-int at value) (make <e-int> #:at at #:value value))
(define (e-str at value) (make <e-str> #:at at #:value value))
(define (e-bool at value) (make <e-bool> #:at at #:value value))
(define (e-nil at) (make <e-nil> #:at at))
(define (e-unit at) (make <e-unit> #:at at))
(define (e-var at name) (make <e-var> #:at at #:name name))
(define (e-call at callee args) (make <e-call> #:at at #:callee callee #:args args))
(define (e-record at tyname inits) (make <e-record> #:at at #:tyname tyname #:inits inits))
(define (e-index at array index) (make <e-index> #:at at #:array array #:index index))
(define (e-field at record select) (make <e-field> #:at at #:record record #:select select))
(define (e-neg at operand) (make <e-neg> #:at at #:operand operand))
(define (e-bin at op lhs rhs) (make <e-bin> #:at at #:op op #:lhs lhs #:rhs rhs))
(define (e-logic at op lhs rhs) (make <e-logic> #:at at #:op op #:lhs lhs #:rhs rhs))
(define (e-assign at target value) (make <e-assign> #:at at #:target target #:value value))
(define (e-if at test then els) (make <e-if> #:at at #:test test #:then then #:els els))
(define (e-while at test body) (make <e-while> #:at at #:test test #:body body))
(define (e-for at binder lo hi body)
  (make <e-for> #:at at #:binder binder #:lo lo #:hi hi #:body body))
(define (e-break at) (make <e-break> #:at at))
(define (e-seq at items) (make <e-seq> #:at at #:items items))
(define (e-let at decls body) (make <e-let> #:at at #:decls decls #:body body))

(define (set-e-record-inits! e v) (set! (e-record-inits e) v))

(define-class <field-init> (<node>)
  (name #:init-keyword #:name #:getter field-init-name)
  (value #:init-keyword #:value #:getter field-init-value))

(define (field-init name value at) (make <field-init> #:name name #:value value #:at at))
(define (field-init-at f) (node-at f))

;; -- declarations ------------------------------------------------------------

(define-class <decl> (<node>))

(define-class <d-type> (<decl>)
  (binds #:init-keyword #:binds #:getter d-type-binds))

(define-class <d-val> (<decl>)
  (name #:init-keyword #:name #:getter d-val-name)
  (written #:init-keyword #:written #:getter d-val-written)
  (init #:init-keyword #:init #:getter d-val-init)
  (var? #:init-keyword #:var? #:getter d-val-var?)
  (sym #:init-value #f #:accessor d-val-sym))

(define-class <d-fun> (<decl>)
  (binds #:init-keyword #:binds #:getter d-fun-binds))

(define (d-type at binds) (make <d-type> #:at at #:binds binds))
(define (d-val at name written init var?)
  (make <d-val> #:at at #:name name #:written written #:init init #:var? var?))
(define (d-fun at binds) (make <d-fun> #:at at #:binds binds))
(define (set-d-val-sym! d v) (set! (d-val-sym d) v))

(define-class <type-bind> (<node>)
  (name #:init-keyword #:name #:getter type-bind-name)
  (bound #:init-keyword #:bound #:getter type-bind-bound))

(define (type-bind name bound at) (make <type-bind> #:name name #:bound bound #:at at))
(define (type-bind-at b) (node-at b))

(define-class <param> (<node>)
  (name #:init-keyword #:name #:getter param-name)
  (ty #:init-keyword #:ty #:getter param-ty)
  (sym #:init-value #f #:accessor param-sym))

(define (param name ty at) (make <param> #:name name #:ty ty #:at at))
(define (param-at p) (node-at p))
(define (set-param-sym! p v) (set! (param-sym p) v))

(define-class <fun-bind> (<node>)
  (label #:init-keyword #:label #:getter fun-bind-label)
  (params #:init-keyword #:params #:getter fun-bind-params)
  (result #:init-keyword #:result #:getter fun-bind-result)
  (body #:init-keyword #:body #:getter fun-bind-body)
  (sym #:init-value #f #:accessor fun-bind-sym))

(define (fun-bind label params result body at)
  (make <fun-bind> #:label label #:params params #:result result #:body body #:at at))
(define (fun-bind-at b) (node-at b))
(define (set-fun-bind-sym! b v) (set! (fun-bind-sym b) v))

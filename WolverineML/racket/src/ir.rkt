#lang racket/base

;; The three-address IR, and the control flow graph both IRs are written in.
;;
;; There are two instruction sets in this compiler.  This file has the first:
;; three-address code over virtual registers, which is what lowering produces,
;; what `ssa.rkt` puts into SSA and what `opt.rkt` rewrites.  The second is
;; `i:machine`, whose forms and meaning are `mach.rkt`'s.
;;
;; What the two sets share is everything else — the registers, the blocks, the
;; graph, the frame — so the passes that only care about the shape of a function
;; work on either.  That is what `defs`, `uses`, `map-uses`, `with-def` and
;; `has-effect?` are for: an instruction says which register it writes and which
;; it reads, and nothing outside this file asks what it is.
;;
;; An instruction is a struct, and a Racket struct is immutable unless it says
;; otherwise, so rewriting one answers with a new one and the caller puts it back
;; where the old one was.  What holds them is a growable vector, because lowering
;; appends and the later passes replace by index.

(require racket/list
         racket/string
         data/gvector
         "diag.rkt")

(provide (struct-out i:const) (struct-out i:str-const) (struct-out i:move)
         (struct-out i:bin) (struct-out i:cmp) (struct-out i:load) (struct-out i:store)
         (struct-out i:load-slot) (struct-out i:store-slot) (struct-out i:frame-addr)
         (struct-out i:call) (struct-out i:jmp) (struct-out i:cbr) (struct-out i:ret)
         (struct-out i:machine)
         (struct-out phi) (struct-out block) (struct-out func) (struct-out module*)
         (struct-out string-lit) (struct-out allocation)
         WORD ARGUMENT-REGISTERS slot-offset unallocated
         defs uses map-uses with-def has-effect? rename-target
         phi-arg phi-set-arg phi-remove-arg phi-preds
         new-func new-reg! new-slot! block-of add-block! walk order-list
         emit! instrs set-instrs! map-instrs! map-phis! count nth
         terminator succs recompute-preds! reachable drop-unreachable! rpo
         reg-name naming show-instr show-phi show-func show-module
         sorted-keys)

;; -- the frame ---------------------------------------------------------------

(define WORD 8)

;; How many arguments AAPCS64 passes in registers.  The rest go on the stack, and
;; the frame layout below knows where.
(define ARGUMENT-REGISTERS 8)

;; Where a frame slot sits, relative to the frame pointer.
;;
;; Slot 0 of every nested function holds its static link, so a frame chain can be
;; walked without knowing whose frame it is.  Negative slots are the arguments the
;; caller had to pass on the stack: they are already in the frame, above the saved
;; frame record, so nothing has to be copied for them.
(define (slot-offset slot)
  (if (< slot 0) (+ 16 (* WORD (- (- slot) 1))) (* (- WORD) (add1 slot))))

;; -- the instructions --------------------------------------------------------

(struct i:const (dst value) #:transparent)
(struct i:str-const (dst symbol) #:transparent)
(struct i:move (dst src) #:transparent)
(struct i:bin (dst op lhs rhs) #:transparent)
(struct i:cmp (dst op lhs rhs) #:transparent)
(struct i:load (dst base offset) #:transparent)
(struct i:store (base offset src) #:transparent)

;; Read a frame slot of this function — an escaping variable, or a spill.
(struct i:load-slot (dst slot) #:transparent)
(struct i:store-slot (slot src) #:transparent)

;; The frame pointer itself, which is what a static link points at.
(struct i:frame-addr (dst) #:transparent)

;; `dst` is #f when the call writes nothing.
(struct i:call (dst callee args) #:transparent)

(struct i:jmp (target) #:transparent)

;; `code` empty means the branch tests `cond`.  After selection it may instead
;; read the flags a comparison just set, and then it reads no register at all.
(struct i:cbr (cond then els code) #:transparent)

;; `value` is #f for a procedure's return.
(struct i:ret (value) #:transparent)

;; The machine instruction: a form, a register it writes and some it reads.
(struct i:machine (form dst srcs imm symbol effectful) #:transparent)

;; -- what every instruction of either set can be asked -----------------------

;; The register it writes, or #f.
(define (defs i)
  (cond
    [(i:const? i) (i:const-dst i)]
    [(i:str-const? i) (i:str-const-dst i)]
    [(i:move? i) (i:move-dst i)]
    [(i:bin? i) (i:bin-dst i)]
    [(i:cmp? i) (i:cmp-dst i)]
    [(i:load? i) (i:load-dst i)]
    [(i:load-slot? i) (i:load-slot-dst i)]
    [(i:frame-addr? i) (i:frame-addr-dst i)]
    [(i:call? i) (i:call-dst i)]
    [(i:machine? i) (i:machine-dst i)]
    [else #f]))

;; The registers it reads.  A phi's arguments are read on the edges, not where
;; the phi stands, so a phi is not an instruction here at all.
(define (uses i)
  (cond
    [(i:move? i) (list (i:move-src i))]
    [(i:bin? i) (list (i:bin-lhs i) (i:bin-rhs i))]
    [(i:cmp? i) (list (i:cmp-lhs i) (i:cmp-rhs i))]
    [(i:load? i) (list (i:load-base i))]
    [(i:store? i) (list (i:store-base i) (i:store-src i))]
    [(i:store-slot? i) (list (i:store-slot-src i))]
    [(i:call? i) (i:call-args i)]
    [(i:machine? i) (i:machine-srcs i)]
    [(i:cbr? i) (if (string=? (i:cbr-code i) "") (list (i:cbr-cond i)) '())]
    [(i:ret? i) (if (i:ret-value i) (list (i:ret-value i)) '())]
    [else '()]))

;; The same instruction with the registers it reads renamed.
(define (map-uses i f)
  (cond
    [(i:move? i) (i:move (i:move-dst i) (f (i:move-src i)))]
    [(i:bin? i)
     (define lhs (f (i:bin-lhs i)))
     (i:bin (i:bin-dst i) (i:bin-op i) lhs (f (i:bin-rhs i)))]
    [(i:cmp? i)
     (define lhs (f (i:cmp-lhs i)))
     (i:cmp (i:cmp-dst i) (i:cmp-op i) lhs (f (i:cmp-rhs i)))]
    [(i:load? i) (i:load (i:load-dst i) (f (i:load-base i)) (i:load-offset i))]
    [(i:store? i)
     (define base (f (i:store-base i)))
     (i:store base (i:store-offset i) (f (i:store-src i)))]
    [(i:store-slot? i) (i:store-slot (i:store-slot-slot i) (f (i:store-slot-src i)))]
    [(i:call? i) (i:call (i:call-dst i) (i:call-callee i) (map f (i:call-args i)))]
    [(i:machine? i)
     (struct-copy i:machine i [srcs (map f (i:machine-srcs i))])]
    [(i:cbr? i)
     (if (string=? (i:cbr-code i) "")
         (struct-copy i:cbr i [cond (f (i:cbr-cond i))])
         i)]
    [(i:ret? i) (if (i:ret-value i) (i:ret (f (i:ret-value i))) i)]
    [else i]))

;; The same instruction, writing `r` instead.  Only asked of one that writes.
(define (with-def r i)
  (cond
    [(i:const? i) (struct-copy i:const i [dst r])]
    [(i:str-const? i) (struct-copy i:str-const i [dst r])]
    [(i:move? i) (struct-copy i:move i [dst r])]
    [(i:bin? i) (struct-copy i:bin i [dst r])]
    [(i:cmp? i) (struct-copy i:cmp i [dst r])]
    [(i:load? i) (struct-copy i:load i [dst r])]
    [(i:load-slot? i) (struct-copy i:load-slot i [dst r])]
    [(i:frame-addr? i) (i:frame-addr r)]
    [(i:call? i) (struct-copy i:call i [dst r])]
    [(i:machine? i) (struct-copy i:machine i [dst r])]
    [else (error 'with-def "this instruction defines nothing")]))

;; True when it has to be kept even if its result is dead.
(define (has-effect? i)
  (cond
    [(i:machine? i) (i:machine-effectful i)]
    [else (or (i:store? i) (i:store-slot? i) (i:call? i)
              (i:jmp? i) (i:cbr? i) (i:ret? i))]))

;; The same terminator, with one of its targets renamed.
(define (rename-target old fresh i)
  (cond
    [(i:jmp? i) (if (equal? (i:jmp-target i) old) (i:jmp fresh) i)]
    [(i:cbr? i)
     (struct-copy i:cbr i
                  [then (if (equal? (i:cbr-then i) old) fresh (i:cbr-then i))]
                  [els (if (equal? (i:cbr-els i) old) fresh (i:cbr-els i))])]
    [else i]))

;; -- phis --------------------------------------------------------------------

;; `args` is a list of `(pred . reg)`, and a list rather than a hash because the
;; order they were placed in is the order a dump has to print them in.
(struct phi (dst args) #:transparent)

(define (phi-arg p pred) (assoc pred (phi-args p)))

;; Keeps an argument where it was, and appends a new one at the end.
(define (phi-set-arg pred r p)
  (if (phi-arg p pred)
      (phi (phi-dst p)
           (for/list ([a (in-list (phi-args p))])
             (if (equal? (car a) pred) (cons pred r) a)))
      (phi (phi-dst p) (append (phi-args p) (list (cons pred r))))))

;; The argument that came in through `pred`, and the phi without it.
(define (phi-remove-arg pred p)
  (define found (phi-arg p pred))
  (and found
       (cons (cdr found)
             (phi (phi-dst p)
                  (filter (λ (a) (not (equal? (car a) pred))) (phi-args p))))))

(define (phi-preds p) (map car (phi-args p)))

;; -- the graph ---------------------------------------------------------------

(struct block (label [phis #:mutable] instrs [preds #:mutable]) #:transparent)

(struct func (label name params depth entry blocks order
                    [nregs #:mutable] [nslots #:mutable] [link-slot #:mutable])
  #:transparent)

;; A literal and the symbol it is emitted under, in the order first seen.
(struct string-lit (symbol text) #:transparent)

(struct module* ([funcs #:mutable] [strings #:mutable]) #:transparent)

;; What the allocator decided.  Not fields of a `func`, because none of it is
;; part of the program: a colouring is an assignment from the program's registers
;; to the machine's, and the emitter is the only thing that reads one.
(struct allocation (colours saved spilled) #:transparent)

(define unallocated (allocation (hash) '() (hash)))

(define (new-func label name depth)
  (func label name (make-gvector) depth "entry" (make-hash) (make-gvector) 0 0 -1))

(define (new-reg! f)
  (define r (func-nregs f))
  (set-func-nregs! f (add1 r))
  r)

(define (new-slot! f)
  (define s (func-nslots f))
  (set-func-nslots! f (add1 s))
  s)

(define (block-of f label)
  (or (hash-ref (func-blocks f) label #f)
      (error 'block-of "no block ~a in ~a" label (func-name f))))

(define (add-block! f label)
  (when (hash-ref (func-blocks f) label #f)
    (error 'add-block! "block ~a already exists" label))
  (define b (block label '() (make-gvector) '()))
  (hash-set! (func-blocks f) label b)
  (gvector-add! (func-order f) label)
  b)

;; Every block, in the order they were made.
(define (walk f) (for/list ([l (in-gvector (func-order f))]) (block-of f l)))

;; The labels, for the places that add blocks to the very list they are walking.
(define (order-list f) (gvector->list (func-order f)))

(define (emit! b i) (gvector-add! (block-instrs b) i))
(define (instrs b) (gvector->list (block-instrs b)))
(define (count b) (gvector-count (block-instrs b)))
(define (nth b at) (gvector-ref (block-instrs b) at))

(define (set-instrs! b list)
  (define g (block-instrs b))
  (let loop () (when (> (gvector-count g) 0) (gvector-remove-last! g) (loop)))
  (for ([i (in-list list)]) (gvector-add! g i)))

;; Put every instruction through `f` and keep the answer where it came from,
;; which is what a pass that rewrites instructions does.
(define (map-instrs! b f)
  (define g (block-instrs b))
  (for ([at (in-range (gvector-count g))])
    (gvector-set! g at (f (gvector-ref g at)))))

(define (map-phis! b f) (set-block-phis! b (map f (block-phis b))))

(define (terminator b)
  (when (zero? (count b)) (error 'terminator "block ~a is unterminated" (block-label b)))
  (define last (nth b (sub1 (count b))))
  (unless (or (i:jmp? last) (i:cbr? last) (i:ret? last))
    (error 'terminator "block ~a falls through" (block-label b)))
  last)

(define (succs b)
  (define t (terminator b))
  (cond
    [(i:jmp? t) (list (i:jmp-target t))]
    [(i:cbr? t)
     (if (equal? (i:cbr-then t) (i:cbr-els t))
         (list (i:cbr-then t))
         (list (i:cbr-then t) (i:cbr-els t)))]
    [else '()]))

;; -- rewiring ----------------------------------------------------------------

(define (recompute-preds! f)
  (for ([b (in-list (walk f))]) (set-block-preds! b '()))
  ;; Built by prepending and reversed once, because the order predecessors are
  ;; listed in is what a dump prints.
  (for ([b (in-list (walk f))])
    (for ([s (in-list (succs b))])
      (define t (block-of f s))
      (set-block-preds! t (cons (block-label b) (block-preds t)))))
  (for ([b (in-list (walk f))]) (set-block-preds! b (reverse (block-preds b)))))

(define (reachable f)
  (define seen (make-hash))
  (let go ([label (func-entry f)])
    (unless (hash-ref seen label #f)
      (hash-set! seen label #t)
      (for ([s (in-list (succs (block-of f label)))]) (go s))))
  seen)

(define (drop-unreachable! f)
  (define live (reachable f))
  (define kept (for/list ([l (in-gvector (func-order f))] #:when (hash-ref live l #f)) l))
  (for ([l (in-gvector (func-order f))] #:unless (hash-ref live l #f))
    (hash-remove! (func-blocks f) l))
  (let loop () (when (> (gvector-count (func-order f)) 0)
                 (gvector-remove-last! (func-order f)) (loop)))
  (for ([l (in-list kept)]) (gvector-add! (func-order f) l))
  (for ([b (in-list (walk f))])
    (map-phis! b (λ (p)
                   (phi (phi-dst p)
                        (filter (λ (a) (hash-ref live (car a) #f)) (phi-args p))))))
  (recompute-preds! f))

;; Reverse post-order, which is the order every dataflow pass walks in.
(define (rpo f)
  (define seen (make-hash))
  (define post '())
  (let go ([label (func-entry f)])
    (unless (hash-ref seen label #f)
      (hash-set! seen label #t)
      (for ([s (in-list (succs (block-of f label)))]) (go s))
      (set! post (cons label post))))
  post)

;; -- printing ----------------------------------------------------------------

(define (reg-name colours r)
  (define c (hash-ref colours r #f))
  (if c (format "%~a:~a" r c) (format "%~a" r)))

(define (naming colours) (λ (r) (reg-name colours r)))

(define (show-instr name i)
  (define (joined rs) (string-join (map name rs) ", "))
  (cond
    [(i:const? i) (format "~a = ~a" (name (i:const-dst i)) (i:const-value i))]
    [(i:str-const? i) (format "~a = &~a" (name (i:str-const-dst i)) (i:str-const-symbol i))]
    [(i:move? i) (format "~a = ~a" (name (i:move-dst i)) (name (i:move-src i)))]
    [(i:bin? i) (format "~a = ~a ~a ~a" (name (i:bin-dst i)) (name (i:bin-lhs i))
                        (i:bin-op i) (name (i:bin-rhs i)))]
    [(i:cmp? i) (format "~a = ~a ~a ~a" (name (i:cmp-dst i)) (name (i:cmp-lhs i))
                        (i:cmp-op i) (name (i:cmp-rhs i)))]
    [(i:load? i) (format "~a = [~a + ~a]" (name (i:load-dst i)) (name (i:load-base i))
                         (i:load-offset i))]
    [(i:store? i) (format "[~a + ~a] = ~a" (name (i:store-base i)) (i:store-offset i)
                          (name (i:store-src i)))]
    [(i:load-slot? i) (format "~a = slot~a" (name (i:load-slot-dst i))
                              (i:load-slot-slot i))]
    [(i:store-slot? i) (format "slot~a = ~a" (i:store-slot-slot i)
                               (name (i:store-slot-src i)))]
    [(i:frame-addr? i) (format "~a = frame" (name (i:frame-addr-dst i)))]
    [(i:call? i)
     (define call (format "~a(~a)" (i:call-callee i) (joined (i:call-args i))))
     (if (i:call-dst i) (format "~a = ~a" (name (i:call-dst i)) call) call)]
    [(i:jmp? i) (format "jmp ~a" (i:jmp-target i))]
    [(i:cbr? i)
     (define test (if (string=? (i:cbr-code i) "")
                      (format "~a ?" (name (i:cbr-cond i)))
                      (format "~a?" (i:cbr-code i))))
     (format "br ~a ~a : ~a" test (i:cbr-then i) (i:cbr-els i))]
    [(i:ret? i) (if (i:ret-value i) (format "ret ~a" (name (i:ret-value i))) "ret")]
    [else
     (define operands
       (append (map name (i:machine-srcs i))
               (cond
                 [(not (string=? (i:machine-symbol i) "")) (list (i:machine-symbol i))]
                 [(or (not (zero? (i:machine-imm i)))
                      (string=? (i:machine-form i) "const"))
                  (list (format "#~a" (i:machine-imm i)))]
                 [else '()])))
     (define written
       (string-trim (format "~a ~a" (i:machine-form i) (string-join operands ", "))
                    #:left? #f))
     (if (i:machine-dst i)
         (format "~a = ~a" (name (i:machine-dst i)) written)
         written)]))

(define (show-phi name p)
  (format "~a = phi [~a]" (name (phi-dst p))
          (string-join (for/list ([a (in-list (phi-args p))])
                         (format "~a: ~a" (car a) (name (cdr a))))
                       ", ")))

(define (show-func f [alloc unallocated])
  (define name (naming (allocation-colours alloc)))
  (define out
    (list (format "fun ~a(~a)  ; depth ~a, ~a slots" (func-label f)
                  (string-join (for/list ([p (in-gvector (func-params f))]) (name p)) ", ")
                  (func-depth f) (func-nslots f))))
  (for ([b (in-list (walk f))])
    (define preds (if (null? (block-preds b))
                      ""
                      (string-append "  ; preds: " (string-join (block-preds b) ", "))))
    (set! out (cons (format "~a:~a" (block-label b) preds) out))
    (for ([p (in-list (block-phis b))])
      (set! out (cons (string-append "    " (show-phi name p)) out)))
    (for ([i (in-list (instrs b))])
      (set! out (cons (string-append "    " (show-instr name i)) out))))
  (string-join (reverse out) "\n"))

(define (show-module m [allocs (hash)])
  (define parts
    (for/list ([f (in-list (module*-funcs m))])
      (show-func f (hash-ref allocs (func-label f) unallocated))))
  (define with-strings
    (if (null? (module*-strings m))
        parts
        (append parts
                (list (string-join
                       (for/list ([s (in-list (module*-strings m))])
                         (format "~a: \"~a\"" (string-lit-symbol s) (string-lit-text s)))
                       "\n")))))
  (string-append (string-join with-strings "\n\n") "\n"))

;; A hash walked in order, which is what every set in the allocator means.
(define (sorted-keys h) (sort (hash-keys h) <))

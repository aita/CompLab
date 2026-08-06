;;; The three-address IR, and the control flow graph both IRs are written in.
;;;
;;; There are two instruction sets in this compiler.  This file has the first:
;;; three-address code over virtual registers, which is what lowering produces,
;;; what `ssa.scm` puts into SSA and what `opt.scm` rewrites.  The second is
;;; `<i-machine>`, whose forms and meaning are `mach.scm`'s.
;;;
;;; What the two sets share is everything else — the registers, the blocks, the
;;; graph, the frame — so the passes that only care about the shape of a
;;; function work on either.  That is what `defs`, `uses`, `map-uses`,
;;; `with-def` and `has-effect?` are: five generic functions, each with a method
;;; per instruction class.  An instruction says which register it writes and
;;; which it reads, and nothing outside this file asks what it is.
;;;
;;; Adding an instruction is therefore adding a class and the methods that
;;; answer for it, and the answer lives next to the thing it is about rather
;;; than in five tables that have to be kept in step.  Where two instructions
;;; are the same shape they share a base class and one method between them, and
;;; `(make (class-of i) ...)` is what rebuilds whichever of the two it was.

(define-module (wolv ir)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (first second last delete-duplicates))
  #:use-module (ice-9 format)
  #:export (<instr>
            <i-const> i-const i-const-value
            <i-str-const> i-str-const i-str-const-symbol
            <i-move> i-move i-move-dst i-move-src
            <i-arith> arith-op arith-lhs arith-rhs
            <i-bin> i-bin i-bin-op i-bin-lhs i-bin-rhs
            <i-cmp> i-cmp i-cmp-op i-cmp-lhs i-cmp-rhs
            <i-load> i-load i-load-base i-load-offset
            <i-store> i-store i-store-base i-store-offset i-store-src
            <i-load-slot> i-load-slot i-load-slot-slot
            <i-store-slot> i-store-slot i-store-slot-slot i-store-slot-src
            <i-frame-addr> i-frame-addr
            <i-call> i-call i-call-callee i-call-args
            <i-jmp> i-jmp i-jmp-target
            <i-cbr> i-cbr i-cbr-test i-cbr-then i-cbr-else i-cbr-code
            <i-ret> i-ret i-ret-value
            <i-machine> i-machine i-machine-form i-machine-srcs i-machine-imm
            i-machine-symbol i-machine-effectful
            instr-dst
            <phi> phi phi-dst phi-args phi-arg phi-set-arg phi-remove-arg phi-preds
            <block> block-label block-phis set-block-phis!
            block-preds set-block-preds!
            <func> func-label func-name func-params set-func-params! func-depth
            func-entry func-blocks func-order func-nregs set-func-nregs!
            func-nslots set-func-nslots! func-link-slot set-func-link-slot!
            <ir-module> module-funcs set-module-funcs! module-strings set-module-strings!
            new-module
            <string-lit> string-lit string-lit-symbol string-lit-text
            <allocation> allocation allocation-colours allocation-saved
            allocation-spilled unallocated
            WORD ARGUMENT-REGISTERS slot-offset
            defs uses map-uses with-def has-effect? rename-target show-instr
            new-func new-reg! new-slot! block-of add-block! walk order-list
            emit! instrs set-instrs! map-instrs! map-phis! count nth
            terminator succs recompute-preds! reachable drop-unreachable! rpo
            reg-name naming show-phi show-func show-module sorted-keys))

;; -- the frame ---------------------------------------------------------------

(define WORD 8)

;; How many arguments AAPCS64 passes in registers.  The rest go on the stack,
;; and the frame layout below knows where.
(define ARGUMENT-REGISTERS 8)

;; Where a frame slot sits, relative to the frame pointer.
;;
;; Slot 0 of every nested function holds its static link, so a frame chain can
;; be walked without knowing whose frame it is.  Negative slots are the
;; arguments the caller had to pass on the stack: they are already in the frame,
;; above the saved frame record, so nothing has to be copied for them.
(define (slot-offset slot)
  (if (< slot 0)
      (+ 16 (* WORD (- (- slot) 1)))
      (* (- WORD) (+ slot 1))))

;; -- the instructions --------------------------------------------------------

(define-class <instr> ())

;; Nearly every instruction that writes writes into a slot of this name, so the
;; getter is one generic with a method for each of them.
(define-class <i-const> (<instr>)
  (dst #:init-keyword #:dst #:getter instr-dst)
  (value #:init-keyword #:value #:getter i-const-value))

(define-class <i-str-const> (<instr>)
  (dst #:init-keyword #:dst #:getter instr-dst)
  (symbol #:init-keyword #:symbol #:getter i-str-const-symbol))

(define-class <i-move> (<instr>)
  (dst #:init-keyword #:dst #:getter instr-dst)
  (src #:init-keyword #:src #:getter i-move-src))

;; `i-bin` and `i-cmp` are the same shape and differ in what they mean, so they
;; share a base and the methods that only care about the shape.
(define-class <i-arith> (<instr>)
  (dst #:init-keyword #:dst #:getter instr-dst)
  (op #:init-keyword #:op #:getter arith-op)
  (lhs #:init-keyword #:lhs #:getter arith-lhs)
  (rhs #:init-keyword #:rhs #:getter arith-rhs))

(define-class <i-bin> (<i-arith>))
(define-class <i-cmp> (<i-arith>))

(define-class <i-load> (<instr>)
  (dst #:init-keyword #:dst #:getter instr-dst)
  (base #:init-keyword #:base #:getter i-load-base)
  (offset #:init-keyword #:offset #:getter i-load-offset))

(define-class <i-store> (<instr>)
  (base #:init-keyword #:base #:getter i-store-base)
  (offset #:init-keyword #:offset #:getter i-store-offset)
  (src #:init-keyword #:src #:getter i-store-src))

;; Read a frame slot of this function — an escaping variable, or a spill.
(define-class <i-load-slot> (<instr>)
  (dst #:init-keyword #:dst #:getter instr-dst)
  (slot #:init-keyword #:slot #:getter i-load-slot-slot))

(define-class <i-store-slot> (<instr>)
  (slot #:init-keyword #:slot #:getter i-store-slot-slot)
  (src #:init-keyword #:src #:getter i-store-slot-src))

;; The frame pointer itself, which is what a static link points at.
(define-class <i-frame-addr> (<instr>)
  (dst #:init-keyword #:dst #:getter instr-dst))

;; `dst` is #f when the call writes nothing.
(define-class <i-call> (<instr>)
  (dst #:init-keyword #:dst #:getter instr-dst)
  (callee #:init-keyword #:callee #:getter i-call-callee)
  (args #:init-keyword #:args #:getter i-call-args))

(define-class <i-jmp> (<instr>)
  (target #:init-keyword #:target #:getter i-jmp-target))

;; `code` empty means the branch tests its register.  After selection it may
;; instead read the flags a comparison just set, and then it reads no register.
(define-class <i-cbr> (<instr>)
  (test #:init-keyword #:test #:getter i-cbr-test)
  (then #:init-keyword #:then #:getter i-cbr-then)
  (els #:init-keyword #:els #:getter i-cbr-else)
  (code #:init-keyword #:code #:getter i-cbr-code))

;; `value` is #f for a procedure's return.
(define-class <i-ret> (<instr>)
  (value #:init-keyword #:value #:getter i-ret-value))

;; The machine instruction: a form, a register it writes and some it reads.
(define-class <i-machine> (<instr>)
  (form #:init-keyword #:form #:getter i-machine-form)
  (dst #:init-keyword #:dst #:getter instr-dst)
  (srcs #:init-keyword #:srcs #:getter i-machine-srcs)
  (imm #:init-keyword #:imm #:getter i-machine-imm)
  (symbol #:init-keyword #:symbol #:getter i-machine-symbol)
  (effectful #:init-keyword #:effectful #:getter i-machine-effectful))

(define (i-const dst value) (make <i-const> #:dst dst #:value value))
(define (i-str-const dst symbol) (make <i-str-const> #:dst dst #:symbol symbol))
(define (i-move dst src) (make <i-move> #:dst dst #:src src))
(define (i-bin dst op lhs rhs) (make <i-bin> #:dst dst #:op op #:lhs lhs #:rhs rhs))
(define (i-cmp dst op lhs rhs) (make <i-cmp> #:dst dst #:op op #:lhs lhs #:rhs rhs))
(define (i-load dst base offset) (make <i-load> #:dst dst #:base base #:offset offset))
(define (i-store base offset src) (make <i-store> #:base base #:offset offset #:src src))
(define (i-load-slot dst slot) (make <i-load-slot> #:dst dst #:slot slot))
(define (i-store-slot slot src) (make <i-store-slot> #:slot slot #:src src))
(define (i-frame-addr dst) (make <i-frame-addr> #:dst dst))
(define (i-call dst callee args) (make <i-call> #:dst dst #:callee callee #:args args))
(define (i-jmp target) (make <i-jmp> #:target target))
(define (i-cbr test then els code)
  (make <i-cbr> #:test test #:then then #:els els #:code code))
(define (i-ret value) (make <i-ret> #:value value))
(define (i-machine form dst srcs imm symbol effectful)
  (make <i-machine> #:form form #:dst dst #:srcs srcs #:imm imm
        #:symbol symbol #:effectful effectful))

;; The three below are the same shape as their base class but not the same
;; meaning, so `i-move-dst` says what it means where a reader would otherwise
;; have to know that `instr-dst` was the right generic to ask.
(define (i-move-dst i) (instr-dst i))
(define (i-bin-op i) (arith-op i))
(define (i-bin-lhs i) (arith-lhs i))
(define (i-bin-rhs i) (arith-rhs i))
(define (i-cmp-op i) (arith-op i))
(define (i-cmp-lhs i) (arith-lhs i))
(define (i-cmp-rhs i) (arith-rhs i))

;; -- what every instruction of either set can be asked ------------------------

;; The register it writes, or #f.
(define-generic defs)
(define-method (defs (i <instr>)) #f)
(define-method (defs (i <i-const>)) (instr-dst i))
(define-method (defs (i <i-str-const>)) (instr-dst i))
(define-method (defs (i <i-move>)) (instr-dst i))
(define-method (defs (i <i-arith>)) (instr-dst i))
(define-method (defs (i <i-load>)) (instr-dst i))
(define-method (defs (i <i-load-slot>)) (instr-dst i))
(define-method (defs (i <i-frame-addr>)) (instr-dst i))
(define-method (defs (i <i-call>)) (instr-dst i))
(define-method (defs (i <i-machine>)) (instr-dst i))

;; The registers it reads.  A phi's arguments are read on the edges, not where
;; the phi stands, so a phi is not an instruction here at all.
(define-generic uses)
(define-method (uses (i <instr>)) '())
(define-method (uses (i <i-move>)) (list (i-move-src i)))
(define-method (uses (i <i-arith>)) (list (arith-lhs i) (arith-rhs i)))
(define-method (uses (i <i-load>)) (list (i-load-base i)))
(define-method (uses (i <i-store>)) (list (i-store-base i) (i-store-src i)))
(define-method (uses (i <i-store-slot>)) (list (i-store-slot-src i)))
(define-method (uses (i <i-call>)) (i-call-args i))
(define-method (uses (i <i-machine>)) (i-machine-srcs i))
(define-method (uses (i <i-cbr>))
  (if (string=? (i-cbr-code i) "") (list (i-cbr-test i)) '()))
(define-method (uses (i <i-ret>))
  (if (i-ret-value i) (list (i-ret-value i)) '()))

;; The same instruction with the registers it reads renamed.
;;
;; `f` allocates — renaming a variable that was never written invents a register
;; for it — so the order the operands are rewritten in is the order they are
;; numbered in, and a `let*` is what says so.
(define-generic map-uses)
(define-method (map-uses (i <instr>) f) i)
(define-method (map-uses (i <i-move>) f) (i-move (instr-dst i) (f (i-move-src i))))
(define-method (map-uses (i <i-arith>) f)
  (let* ((lhs (f (arith-lhs i))) (rhs (f (arith-rhs i))))
    (make (class-of i) #:dst (instr-dst i) #:op (arith-op i) #:lhs lhs #:rhs rhs)))
(define-method (map-uses (i <i-load>) f)
  (i-load (instr-dst i) (f (i-load-base i)) (i-load-offset i)))
(define-method (map-uses (i <i-store>) f)
  (let* ((base (f (i-store-base i))) (src (f (i-store-src i))))
    (i-store base (i-store-offset i) src)))
(define-method (map-uses (i <i-store-slot>) f)
  (i-store-slot (i-store-slot-slot i) (f (i-store-slot-src i))))
(define-method (map-uses (i <i-call>) f)
  (i-call (instr-dst i) (i-call-callee i) (map-in-order f (i-call-args i))))
(define-method (map-uses (i <i-machine>) f)
  (i-machine (i-machine-form i) (instr-dst i) (map-in-order f (i-machine-srcs i))
             (i-machine-imm i) (i-machine-symbol i) (i-machine-effectful i)))
(define-method (map-uses (i <i-cbr>) f)
  (if (string=? (i-cbr-code i) "")
      (i-cbr (f (i-cbr-test i)) (i-cbr-then i) (i-cbr-else i) (i-cbr-code i))
      i))
(define-method (map-uses (i <i-ret>) f)
  (if (i-ret-value i) (i-ret (f (i-ret-value i))) i))

;; The same instruction, writing `r` instead.  Only asked of one that writes.
(define-generic with-def)
(define-method (with-def (i <instr>) r)
  (error "this instruction defines nothing"))
(define-method (with-def (i <i-const>) r) (i-const r (i-const-value i)))
(define-method (with-def (i <i-str-const>) r) (i-str-const r (i-str-const-symbol i)))
(define-method (with-def (i <i-move>) r) (i-move r (i-move-src i)))
(define-method (with-def (i <i-arith>) r)
  (make (class-of i) #:dst r #:op (arith-op i) #:lhs (arith-lhs i) #:rhs (arith-rhs i)))
(define-method (with-def (i <i-load>) r)
  (i-load r (i-load-base i) (i-load-offset i)))
(define-method (with-def (i <i-load-slot>) r) (i-load-slot r (i-load-slot-slot i)))
(define-method (with-def (i <i-frame-addr>) r) (i-frame-addr r))
(define-method (with-def (i <i-call>) r) (i-call r (i-call-callee i) (i-call-args i)))
(define-method (with-def (i <i-machine>) r)
  (i-machine (i-machine-form i) r (i-machine-srcs i) (i-machine-imm i)
             (i-machine-symbol i) (i-machine-effectful i)))

;; True when it has to be kept even if its result is dead.
(define-generic has-effect?)
(define-method (has-effect? (i <instr>)) #f)
(define-method (has-effect? (i <i-store>)) #t)
(define-method (has-effect? (i <i-store-slot>)) #t)
(define-method (has-effect? (i <i-call>)) #t)
(define-method (has-effect? (i <i-jmp>)) #t)
(define-method (has-effect? (i <i-cbr>)) #t)
(define-method (has-effect? (i <i-ret>)) #t)
(define-method (has-effect? (i <i-machine>)) (i-machine-effectful i))

;; The same terminator, with one of its targets renamed.
(define-generic rename-target)
(define-method (rename-target (i <instr>) old fresh) i)
(define-method (rename-target (i <i-jmp>) old fresh)
  (i-jmp (if (equal? (i-jmp-target i) old) fresh (i-jmp-target i))))
(define-method (rename-target (i <i-cbr>) old fresh)
  (let ((swap (lambda (label) (if (equal? label old) fresh label))))
    (i-cbr (i-cbr-test i) (swap (i-cbr-then i)) (swap (i-cbr-else i)) (i-cbr-code i))))

;; -- phis --------------------------------------------------------------------

;; `args` is a list of `(pred . reg)`, and a list rather than a table because
;; the order they were placed in is the order a dump has to print them in.
(define-class <phi> ()
  (dst #:init-keyword #:dst #:getter phi-dst)
  (args #:init-keyword #:args #:getter phi-args))

(define (phi dst args) (make <phi> #:dst dst #:args args))

(define (phi-arg p pred) (assoc pred (phi-args p)))

;; Keeps an argument where it was, and appends a new one at the end.
(define (phi-set-arg pred r p)
  (if (phi-arg p pred)
      (phi (phi-dst p)
           (map (lambda (a) (if (equal? (car a) pred) (cons pred r) a)) (phi-args p)))
      (phi (phi-dst p) (append (phi-args p) (list (cons pred r))))))

;; The argument that came in through `pred`, and the phi without it.
(define (phi-remove-arg pred p)
  (let ((found (phi-arg p pred)))
    (and found
         (cons (cdr found)
               (phi (phi-dst p)
                    (filter (lambda (a) (not (equal? (car a) pred))) (phi-args p)))))))

(define (phi-preds p) (map car (phi-args p)))

;; -- the graph ---------------------------------------------------------------

(define-class <block> ()
  (label #:init-keyword #:label #:getter block-label)
  (phis #:init-value '() #:accessor block-phis)
  (instrs #:init-value '() #:accessor block-instrs)
  (preds #:init-value '() #:accessor block-preds))

(define-class <func> ()
  (label #:init-keyword #:label #:getter func-label)
  (name #:init-keyword #:name #:getter func-name)
  (params #:init-value '() #:accessor func-params)
  (depth #:init-keyword #:depth #:getter func-depth)
  (entry #:init-value "entry" #:getter func-entry)
  (blocks #:init-thunk make-hash-table #:getter func-blocks)
  (order #:init-value '() #:accessor func-order)
  (nregs #:init-value 0 #:accessor func-nregs)
  (nslots #:init-value 0 #:accessor func-nslots)
  (link-slot #:init-value -1 #:accessor func-link-slot))

;; A literal and the symbol it is emitted under, in the order first seen.
(define-class <string-lit> ()
  (symbol #:init-keyword #:symbol #:getter string-lit-symbol)
  (text #:init-keyword #:text #:getter string-lit-text))

(define (string-lit symbol text) (make <string-lit> #:symbol symbol #:text text))

(define-class <ir-module> ()
  (funcs #:init-value '() #:accessor module-funcs)
  (strings #:init-value '() #:accessor module-strings))

(define (new-module) (make <ir-module>))

;; What the allocator decided.  Not slots of a `<func>`, because none of it is
;; part of the program: a colouring is an assignment from the program's
;; registers to the machine's, and the emitter is the only thing that reads one.
(define-class <allocation> ()
  (colours #:init-keyword #:colours #:getter allocation-colours)
  (saved #:init-keyword #:saved #:getter allocation-saved)
  (spilled #:init-keyword #:spilled #:getter allocation-spilled))

(define (allocation colours saved spilled)
  (make <allocation> #:colours colours #:saved saved #:spilled spilled))

(define unallocated (allocation (make-hash-table) '() (make-hash-table)))

(define (set-func-params! f v) (set! (func-params f) v))
(define (set-func-nregs! f v) (set! (func-nregs f) v))
(define (set-func-nslots! f v) (set! (func-nslots f) v))
(define (set-func-link-slot! f v) (set! (func-link-slot f) v))
(define (set-block-phis! b v) (set! (block-phis b) v))
(define (set-block-preds! b v) (set! (block-preds b) v))
(define (set-module-funcs! m v) (set! (module-funcs m) v))
(define (set-module-strings! m v) (set! (module-strings m) v))

(define (new-func label name depth)
  (make <func> #:label label #:name name #:depth depth))

(define (new-reg! f)
  (let ((r (func-nregs f)))
    (set! (func-nregs f) (+ r 1))
    r))

(define (new-slot! f)
  (let ((s (func-nslots f)))
    (set! (func-nslots f) (+ s 1))
    s))

(define (block-of f label)
  (or (hash-ref (func-blocks f) label #f)
      (error "no such block" label (func-name f))))

(define (add-block! f label)
  (when (hash-ref (func-blocks f) label #f)
    (error "block already exists" label))
  (let ((b (make <block> #:label label)))
    (hash-set! (func-blocks f) label b)
    (set! (func-order f) (append (func-order f) (list label)))
    b))

;; Every block, in the order they were made.
(define (walk f) (map (lambda (l) (block-of f l)) (func-order f)))

;; The labels, for the places that add blocks to the very list they are walking.
(define (order-list f) (func-order f))

(define (emit! b i) (set! (block-instrs b) (append (block-instrs b) (list i))))
(define (instrs b) (block-instrs b))
(define (count b) (length (block-instrs b)))
(define (nth b at) (list-ref (block-instrs b) at))
(define (set-instrs! b list) (set! (block-instrs b) list))

;; Put every instruction through `f` and keep the answer where it came from,
;; which is what a pass that rewrites instructions does.
(define (map-instrs! b f) (set! (block-instrs b) (map-in-order f (block-instrs b))))

(define (map-phis! b f) (set! (block-phis b) (map-in-order f (block-phis b))))

(define (terminator b)
  (when (zero? (count b)) (error "block is unterminated" (block-label b)))
  (let ((final (last (block-instrs b))))
    (unless (or (is-a? final <i-jmp>) (is-a? final <i-cbr>) (is-a? final <i-ret>))
      (error "block falls through" (block-label b)))
    final))

(define-generic instr-succs)
(define-method (instr-succs (i <instr>)) '())
(define-method (instr-succs (i <i-jmp>)) (list (i-jmp-target i)))
(define-method (instr-succs (i <i-cbr>))
  (if (equal? (i-cbr-then i) (i-cbr-else i))
      (list (i-cbr-then i))
      (list (i-cbr-then i) (i-cbr-else i))))

(define (succs b) (instr-succs (terminator b)))

;; -- rewiring ----------------------------------------------------------------

(define (recompute-preds! f)
  (for-each (lambda (b) (set! (block-preds b) '())) (walk f))
  ;; Built by prepending and reversed once, because the order predecessors are
  ;; listed in is what a dump prints.
  (for-each (lambda (b)
              (for-each (lambda (s)
                          (let ((t (block-of f s)))
                            (set! (block-preds t)
                                  (cons (block-label b) (block-preds t)))))
                        (succs b)))
            (walk f))
  (for-each (lambda (b) (set! (block-preds b) (reverse (block-preds b)))) (walk f)))

(define (reachable f)
  (let ((seen (make-hash-table)))
    (let go ((label (func-entry f)))
      (unless (hash-ref seen label #f)
        (hash-set! seen label #t)
        (for-each go (succs (block-of f label)))))
    seen))

(define (drop-unreachable! f)
  (let* ((live (reachable f))
         (kept (filter (lambda (l) (hash-ref live l #f)) (func-order f))))
    (for-each (lambda (l)
                (unless (hash-ref live l #f) (hash-remove! (func-blocks f) l)))
              (func-order f))
    (set! (func-order f) kept)
    (for-each (lambda (b)
                (map-phis! b (lambda (p)
                               (phi (phi-dst p)
                                    (filter (lambda (a) (hash-ref live (car a) #f))
                                            (phi-args p))))))
              (walk f))
    (recompute-preds! f)))

;; Reverse post-order, which is the order every dataflow pass walks in.
(define (rpo f)
  (let ((seen (make-hash-table))
        (post '()))
    (let go ((label (func-entry f)))
      (unless (hash-ref seen label #f)
        (hash-set! seen label #t)
        (for-each go (succs (block-of f label)))
        (set! post (cons label post))))
    post))

;; -- printing ----------------------------------------------------------------

(define (reg-name colours r)
  (let ((c (hash-ref colours r #f)))
    (if c (format #f "%~a:~a" r c) (format #f "%~a" r))))

(define (naming colours) (lambda (r) (reg-name colours r)))

(define-generic show-instr)

(define-method (show-instr (i <i-const>) name)
  (format #f "~a = ~a" (name (instr-dst i)) (i-const-value i)))
(define-method (show-instr (i <i-str-const>) name)
  (format #f "~a = &~a" (name (instr-dst i)) (i-str-const-symbol i)))
(define-method (show-instr (i <i-move>) name)
  (format #f "~a = ~a" (name (instr-dst i)) (name (i-move-src i))))
(define-method (show-instr (i <i-arith>) name)
  (format #f "~a = ~a ~a ~a" (name (instr-dst i)) (name (arith-lhs i))
          (arith-op i) (name (arith-rhs i))))
(define-method (show-instr (i <i-load>) name)
  (format #f "~a = [~a + ~a]" (name (instr-dst i)) (name (i-load-base i))
          (i-load-offset i)))
(define-method (show-instr (i <i-store>) name)
  (format #f "[~a + ~a] = ~a" (name (i-store-base i)) (i-store-offset i)
          (name (i-store-src i))))
(define-method (show-instr (i <i-load-slot>) name)
  (format #f "~a = slot~a" (name (instr-dst i)) (i-load-slot-slot i)))
(define-method (show-instr (i <i-store-slot>) name)
  (format #f "slot~a = ~a" (i-store-slot-slot i) (name (i-store-slot-src i))))
(define-method (show-instr (i <i-frame-addr>) name)
  (format #f "~a = frame" (name (instr-dst i))))
(define-method (show-instr (i <i-call>) name)
  (let ((call (format #f "~a(~a)" (i-call-callee i)
                      (string-join (map name (i-call-args i)) ", "))))
    (if (instr-dst i) (format #f "~a = ~a" (name (instr-dst i)) call) call)))
(define-method (show-instr (i <i-jmp>) name)
  (format #f "jmp ~a" (i-jmp-target i)))
(define-method (show-instr (i <i-cbr>) name)
  (let ((test (if (string=? (i-cbr-code i) "")
                  (format #f "~a ?" (name (i-cbr-test i)))
                  (format #f "~a?" (i-cbr-code i)))))
    (format #f "br ~a ~a : ~a" test (i-cbr-then i) (i-cbr-else i))))
(define-method (show-instr (i <i-ret>) name)
  (if (i-ret-value i) (format #f "ret ~a" (name (i-ret-value i))) "ret"))
(define-method (show-instr (i <i-machine>) name)
  (let* ((operands
          (append (map name (i-machine-srcs i))
                  (cond
                   ((not (string=? (i-machine-symbol i) "")) (list (i-machine-symbol i)))
                   ((or (not (zero? (i-machine-imm i)))
                        (string=? (i-machine-form i) "const"))
                    (list (format #f "#~a" (i-machine-imm i))))
                   (else '()))))
         (written (string-trim-right
                   (format #f "~a ~a" (i-machine-form i) (string-join operands ", ")))))
    (if (instr-dst i)
        (format #f "~a = ~a" (name (instr-dst i)) written)
        written)))

(define (show-phi name p)
  (format #f "~a = phi [~a]" (name (phi-dst p))
          (string-join (map (lambda (a) (format #f "~a: ~a" (car a) (name (cdr a))))
                            (phi-args p))
                       ", ")))

(define* (show-func f #:optional (alloc unallocated))
  (let ((name (naming (allocation-colours alloc)))
        (out '()))
    (define (put text) (set! out (cons text out)))
    (put (format #f "fun ~a(~a)  ; depth ~a, ~a slots" (func-label f)
                 (string-join (map (naming (allocation-colours alloc)) (func-params f)) ", ")
                 (func-depth f) (func-nslots f)))
    (for-each
     (lambda (b)
       (let ((preds (if (null? (block-preds b))
                        ""
                        (string-append "  ; preds: "
                                       (string-join (block-preds b) ", ")))))
         (put (format #f "~a:~a" (block-label b) preds))
         (for-each (lambda (p) (put (string-append "    " (show-phi name p))))
                   (block-phis b))
         (for-each (lambda (i) (put (string-append "    " (show-instr i name))))
                   (instrs b))))
     (walk f))
    (string-join (reverse out) "\n")))

(define* (show-module m #:optional (allocs (make-hash-table)))
  (let* ((parts (map (lambda (f)
                       (show-func f (hash-ref allocs (func-label f) unallocated)))
                     (module-funcs m)))
         (with-strings
          (if (null? (module-strings m))
              parts
              (append parts
                      (list (string-join
                             (map (lambda (s)
                                    (format #f "~a: \"~a\"" (string-lit-symbol s)
                                            (string-lit-text s)))
                                  (module-strings m))
                             "\n"))))))
    (string-append (string-join with-strings "\n\n") "\n")))

;; A table walked in order, which is what every set in the allocator means.
(define (sorted-keys h) (sort (hash-map->list (lambda (k v) k) h) <))

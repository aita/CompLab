#lang racket/base

;; What the allocator and the emitter both have to agree about: the registers.
;;
;; x16 and x17 are the ABI's intra-procedure-call scratch registers, which a
;; linker veneer may clobber at a `bl`.  Nothing of ours is ever live across a
;; call in a caller-saved register, so x16 is allocatable like any other; x17 is
;; the one register kept back, for an address the emitter has to compute after
;; allocation is over.  x18 is the platform register, x29 the frame pointer, x30
;; the link register.

(require racket/list)

(provide CALLER-SAVED CALLEE-SAVED ARGUMENT-REGS SCRATCH
         (struct-out registers) whole-machine anywhere register-count limited)

(define CALLER-SAVED '(9 10 11 12 13 14 15 16 0 1 2 3 4 5 6 7 8))
(define CALLEE-SAVED '(19 20 21 22 23 24 25 26 27 28))
(define ARGUMENT-REGS '(0 1 2 3 4 5 6 7))
(define SCRATCH '(17))

;; The machine an allocator is colouring for.
(struct registers (caller callee) #:transparent)

(define (whole-machine) (registers CALLER-SAVED CALLEE-SAVED))

(define (anywhere m) (append (registers-caller m) (registers-callee m)))
(define (register-count m) (+ (length (registers-caller m)) (length (registers-callee m))))

;; A smaller machine, so that the spiller can be tested on small programs.
(define (limited max-regs)
  (define callee (take CALLEE-SAVED (min (length CALLEE-SAVED) (max 2 (quotient max-regs 2)))))
  (define caller (take CALLER-SAVED (min (length CALLER-SAVED)
                                         (max 1 (- max-regs (length callee))))))
  (registers caller callee))

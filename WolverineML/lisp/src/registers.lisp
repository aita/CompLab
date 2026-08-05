;;;; What the allocator and the emitter both have to agree about: the registers.
;;;;
;;;; x16 and x17 are the ABI's intra-procedure-call scratch registers, which a
;;;; linker veneer may clobber at a `bl`.  Nothing of ours is ever live across
;;;; a call in a caller-saved register, so x16 is allocatable like any other;
;;;; x17 is the one register kept back, for an address the emitter has to
;;;; compute after allocation is over.  x18 is the platform register, x29 the
;;;; frame pointer, x30 the link register.

(defpackage #:wolv.registers
  (:use #:cl)
  (:export #:*caller-saved* #:*callee-saved* #:*argument-regs* #:*scratch*
           #:machine #:make-machine #:machine-caller #:machine-callee
           #:whole-machine #:limited #:anywhere #:register-count))

(in-package #:wolv.registers)

(defparameter *caller-saved* '(9 10 11 12 13 14 15 16 0 1 2 3 4 5 6 7 8))
(defparameter *callee-saved* '(19 20 21 22 23 24 25 26 27 28))
(defparameter *argument-regs* '(0 1 2 3 4 5 6 7))
(defparameter *scratch* '(17))

(defstruct (machine (:constructor make-machine (caller callee)) (:copier nil))
  "The machine the allocator is colouring for."
  caller callee)

(defun whole-machine () (make-machine *caller-saved* *callee-saved*))

(defun anywhere (m) (append (machine-caller m) (machine-callee m)))
(defun register-count (m) (+ (length (machine-caller m)) (length (machine-callee m))))

(defun take (list n)
  "The first N, or all of them -- `subseq` past the end is an error and a
machine asked for more registers than exist is not."
  (subseq list 0 (min n (length list))))

(defun limited (max-regs)
  "A smaller machine, so that the spiller can be tested on small programs."
  (let* ((callee (take *callee-saved* (max 2 (floor max-regs 2))))
         (caller (take *caller-saved* (max 1 (- max-regs (length callee))))))
    (make-machine caller callee)))

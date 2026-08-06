;;; Which colour a value would like, which is the calling convention asking.
;;;
;;; The allocator does not have to satisfy these — a preference is dropped the
;;; moment it clashes with something the colouring actually requires — but
;;; taking one when it is free is what stops the emitter having to move a value
;;; into `x2` on the way into a call, or out of `x0` on the way back from one.

(define-module (wolv hints)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (first))
  #:use-module (wolv registers)
  #:use-module (wolv ir)
  #:export (preferences))

;; The register each value is about to be wanted in, where there is one.
(define (preferences f)
  (let ((wanted (make-hash-table)))
    (let loop ((ps (func-params f)) (regs ARGUMENT-REGS))
      (unless (or (null? ps) (null? regs))
        (hash-set! wanted (car ps) (car regs))
        (loop (cdr ps) (cdr regs))))
    (for-each
     (lambda (b)
       (for-each
        (lambda (i)
          (cond
           ((is-a? i <i-call>)
            (let loop ((args (i-call-args i)) (regs ARGUMENT-REGS))
              (unless (or (null? args) (null? regs))
                (hash-set! wanted (car args) (car regs))
                (loop (cdr args) (cdr regs))))
            (when (instr-dst i) (hash-set! wanted (instr-dst i) (first ARGUMENT-REGS))))
           ((and (is-a? i <i-ret>) (i-ret-value i))
            (hash-set! wanted (i-ret-value i) (first ARGUMENT-REGS)))
           (else *unspecified*)))
        (instrs b)))
     (walk f))
    wanted))

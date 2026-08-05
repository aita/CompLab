;;;; ARMv8 assembly, in AAPCS64.
;;;;
;;;; The frame is the ordinary one.  `x29` points at the saved frame record,
;;;; the slots an escaping variable or a spill lives in are below it, the
;;;; callee-saved registers this function actually used are below those, and
;;;; outgoing stack arguments sit at the bottom, at `sp`, where the callee
;;;; expects them.
;;;;
;;;;     x29 -> | saved x29, x30 |
;;;;            | slot 0         |   x29 - 8      also where a static link points
;;;;            | slot 1         |   x29 - 16
;;;;            | ...            |
;;;;            | saved x19...   |
;;;;     sp  -> | outgoing args  |
;;;;
;;;; A phi that reaches here is a copy on an edge, so the copies go at the end
;;;; of the predecessor, all at once: the values are read before any is
;;;; written, which is what `copies:sequentialize` arranges.  When the copies
;;;; form a cycle it borrows a register the function never used, and when there
;;;; is none it swaps the two ends with three `eor`s, so no register has to be
;;;; reserved for it.

(defpackage #:wolv.emit
  (:use #:cl)
  (:local-nicknames (#:copies #:wolv.copies)
                    (#:ir #:wolv.ir)
                    (#:mach #:wolv.mach)
                    (#:reg #:wolv.registers))
  (:export #:emit-module #:escape #:*borrow-nothing*))

(in-package #:wolv.emit)

(defparameter *unscaled* '(("ldr" . "ldur") ("str" . "stur")))

;; The one register kept back.  A frame big enough to put a slot out of reach
;; of `ldur` is only discovered after allocation has added its spill slots, so
;; the address has to be computed somewhere the allocator does not know about.
(defparameter *spare* (first reg:+scratch+))

;; Nothing of ours is live at the top of the prologue except the incoming
;; arguments, so a caller-saved register that is not one of them is free there.
(defconstant +prologue-temp+ 9)

(defstruct (frame (:constructor %make-frame (slots saved stack-args size))
                  (:copier nil))
  slots saved stack-args size)

(defun make-frame (slots saved stack-args)
  (let ((raw (* ir:+word+ (+ slots (length saved) stack-args))))
    (%make-frame slots saved stack-args (logandc2 (+ raw 15) 15))))

(defun saved-offset (fr index)
  (- (* ir:+word+ (+ (frame-slots fr) index 1))))

(defun frame-of (f)
  (let ((stack-args 0))
    (dolist (b (ir:walk f))
      (dolist (i (ir:block-instrs b))
        (when (typep i 'ir:i-call)
          (setf stack-args
                (max stack-args (- (length (ir:args i)) (length reg:+argument-regs+)))))))
    (make-frame (ir:func-nslots f) (ir:func-saved f) (max stack-args 0))))

(defclass emitter ()
  ((func :initarg :func :reader func)
   (frame :reader frame)
   (out :initform '() :accessor out)          ; in reverse, until `emit` is done
   (epilogue :reader epilogue)
   (read-somewhere :reader read-somewhere)
   (taken :reader taken)))

(defmethod initialize-instance :after ((e emitter) &key)
  (let ((f (func e)))
    (setf (slot-value e 'frame) (frame-of f))
    (setf (slot-value e 'epilogue) (format nil ".Lepi_~A" (ir:func-label f)))
    (setf (slot-value e 'read-somewhere) (registers-read f))
    (setf (slot-value e 'taken)
          (let ((s (make-hash-table :test #'eql)))
            (loop for colour being the hash-values of (ir:func-colours f)
                  do (setf (gethash colour s) t))
            s))))

;; -- helpers ------------------------------------------------------------------

(defun line (e text) (push (format nil "~C~A" #\Tab text) (out e)))
(defun put-label (e text) (push (format nil "~A:" text) (out e)))
(defun raw (e text) (push text (out e)))

(defun colour-of (e r)
  (let ((colour (gethash r (ir:func-colours (func e)))))
    (assert colour () "%~D was never coloured" r)
    colour))

(defun mov (e dst src)
  (unless (eql dst src) (line e (format nil "mov x~D, x~D" dst src))))

(defun immediate (e dst value)
  (let ((word (logand value (1- (ash 1 64)))))
    (if (zerop word)
        (line e (format nil "mov x~D, #0" dst))
        (let ((first-chunk t))
          (loop for i from 0 below 4
                for chunk = (logand (ash word (- (* i 16))) #xFFFF)
                do (unless (zerop chunk)
                     (line e (format nil "~A x~D, #~D~@[, lsl #~D~]"
                                     (if first-chunk "movz" "movk") dst chunk
                                     (when (plusp i) (* i 16))))
                     (setf first-chunk nil)))))))

(defun access (e op reg base offset)
  "`ldr`/`str`, in whichever addressing mode reaches this far."
  (let ((where (if (= base 31) "sp" (format nil "x~D" base))))
    (cond
      ((and (<= 0 offset 32760) (zerop (mod offset ir:+word+)))
       (line e (format nil "~A x~D, [~A, #~D]" op reg where offset)))
      ((<= -256 offset 255)
       (line e (format nil "~A x~D, [~A, #~D]"
                       (cdr (assoc op *unscaled* :test #'string=)) reg where offset)))
      (t
       (immediate e *spare* offset)
       (line e (format nil "~A x~D, [~A, x~D]" op reg where *spare*))))))

;; -- whole functions ----------------------------------------------------------

(defun emit-func (e)
  (let ((f (func e)))
    (raw e (format nil "~C.globl ~A" #\Tab (ir:func-label f)))
    (raw e (format nil "~C.type ~A, %function" #\Tab (ir:func-label f)))
    (put-label e (ir:func-label f))
    (prologue e)
    (let ((order (ir:func-order f)))
      (loop for tail on order
            for name = (first tail)
            do (put-label e (format nil ".L~A_~A" (ir:func-label f) name))
               (emit-block e (ir:block-of f name) (second tail))))
    (put-label e (epilogue e))
    (restore e)
    (line e "mov sp, x29")
    (line e "ldp x29, x30, [sp], #16")
    (line e "ret")
    (raw e (format nil "~C.size ~A, .-~A" #\Tab (ir:func-label f) (ir:func-label f)))
    (nreverse (out e))))

(defun prologue (e)
  (let ((fr (frame e)))
    (line e "stp x29, x30, [sp, #-16]!")
    (line e "mov x29, sp")
    (when (plusp (frame-size fr))
      (if (<= (frame-size fr) 4095)
          (line e (format nil "sub sp, sp, #~D" (frame-size fr)))
          (progn (immediate e +prologue-temp+ (frame-size fr))
                 (line e (format nil "sub sp, sp, x~D" +prologue-temp+)))))
    (loop for r in (frame-saved fr)
          for i from 0
          do (access e "str" r 29 (saved-offset fr i)))
    (emit-copies e (loop for p in (ir:func-params (func e))
                         for colour in reg:+argument-regs+
                         when (gethash p (read-somewhere e))
                           collect (cons (colour-of e p) colour)))))

(defun restore (e)
  (loop for r in (frame-saved (frame e))
        for i from 0
        do (access e "ldr" r 29 (saved-offset (frame e) i))))

(defun emit-block (e b next)
  (dolist (i (butlast (ir:block-instrs b))) (instruction e i))
  (emit-terminator e b next))

(defgeneric emit-terminator-instr (term e b next))

(defun emit-terminator (e b next)
  (emit-terminator-instr (ir:terminator b) e b next))

(defmethod emit-terminator-instr ((term ir:i-jmp) e b next)
  (edge e (ir:block-label b) (ir:target term))
  (unless (equal (ir:target term) next)
    (line e (format nil "b .L~A_~A" (ir:func-label (func e)) (ir:target term)))))

(defmethod emit-terminator-instr ((term ir:i-cbr) e b next)
  (declare (ignore b))
  (let* ((f (func e))
         (then-label (format nil ".L~A_~A" (ir:func-label f) (ir:then term)))
         (else-label (format nil ".L~A_~A" (ir:func-label f) (ir:els term)))
         (code (ir:code term)))
    (assert (null (ir:block-phis (ir:block-of f (ir:then term)))))
    (assert (null (ir:block-phis (ir:block-of f (ir:els term)))))
    (cond
      ((string/= code "")
       (if (equal (ir:then term) next)
           (line e (format nil "b.~A ~A" (mach:opposite-code code) else-label))
           (progn (line e (format nil "b.~A ~A" code then-label))
                  (unless (equal (ir:els term) next)
                    (line e (format nil "b ~A" else-label))))))
      ((equal (ir:then term) next)
       (line e (format nil "cbz x~D, ~A" (colour-of e (ir:test term)) else-label)))
      (t
       (line e (format nil "cbnz x~D, ~A" (colour-of e (ir:test term)) then-label))
       (unless (equal (ir:els term) next)
         (line e (format nil "b ~A" else-label)))))))

(defmethod emit-terminator-instr ((term ir:i-ret) e b next)
  (declare (ignore b))
  (when (ir:value term)
    (mov e (first reg:+argument-regs+) (colour-of e (ir:value term))))
  (when next   ; the epilogue follows the last block
    (line e (format nil "b ~A" (epilogue e)))))

(defun edge (e source target)
  "The copies a phi stands for, made real on this edge."
  (let ((phis (ir:block-phis (ir:block-of (func e) target))))
    (when phis
      (emit-copies e (loop for phi in phis
                           collect (cons (colour-of e (ir:dst phi))
                                         (colour-of e (ir:phi-arg phi source))))))))

(defun emit-copies (e moves)
  (dolist (step (copies:sequentialize moves (borrowed e moves)))
    (etypecase step
      (copies:mov (mov e (copies:mov-dst step) (copies:mov-src step)))
      (copies:swap
       (let ((a (copies:swap-a step)) (b (copies:swap-b step)))
         (line e (format nil "eor x~D, x~D, x~D" a a b))
         (line e (format nil "eor x~D, x~D, x~D" b a b))
         (line e (format nil "eor x~D, x~D, x~D" a a b)))))))

(defvar *borrow-nothing* nil
  "Bound by a test, to force the copies down the path that swaps.")

(defun borrowed (e moves)
  "A register free to clobber here, if the function left one over.

A caller-saved register this function never gave to a value holds nothing of
ours anywhere, and one that this copy neither reads nor writes holds nothing of
the copy's either.  With no such register the copies swap instead, which needs
no scratch at all."
  (when *borrow-nothing* (return-from borrowed nil))
  (let ((touched (loop for (dst . src) in moves append (list dst src))))
    (loop for r in reg:+caller-saved+
          unless (or (gethash r (taken e)) (member r touched))
            return r)))

;; -- one instruction ----------------------------------------------------------

(defgeneric instruction (e instr))

(defmethod instruction (e (i ir:instr))
  (error "cannot emit ~A" (class-name (class-of i))))

(defmethod instruction (e (i ir:i-move))
  (mov e (colour-of e (ir:dst i)) (colour-of e (ir:src i))))

(defmethod instruction (e (i ir:i-load-slot))
  (access e "ldr" (colour-of e (ir:dst i)) 29 (ir:slot-offset (ir:slot i))))

(defmethod instruction (e (i ir:i-store-slot))
  (access e "str" (colour-of e (ir:src i)) 29 (ir:slot-offset (ir:slot i))))

(defmethod instruction (e (i ir:i-frame-addr))
  (mov e (colour-of e (ir:dst i)) 29))

(defmethod instruction (e (i ir:i-call))
  (let ((args (ir:args i))
        (n (length reg:+argument-regs+)))
    (let ((in-registers (loop for a in args
                              for colour in reg:+argument-regs+
                              collect (cons colour (colour-of e a)))))
      (loop for a in (nthcdr n args)
            for index from 0
            do (access e "str" (colour-of e a) 31 (* ir:+word+ index)))
      (emit-copies e in-registers)
      (line e (format nil "bl ~A" (ir:callee i)))
      (when (ir:dst i)
        (mov e (colour-of e (ir:dst i)) (first reg:+argument-regs+))))))

(defmethod instruction (e (i mach:i-mach))
  "Write down one selected instruction, or the sequence it stands for."
  (let ((srcs (mapcar (lambda (s) (colour-of e s)) (mach:srcs i)))
        (form (mach:form i)))
    (cond
      ((string= form "const") (immediate e (colour-of e (ir:dst i)) (mach:imm i)))
      ((string= form "adr")
       (let ((d (colour-of e (ir:dst i))))
         (line e (format nil "adrp x~D, ~A" d (ir:symbol-of i)))
         (line e (format nil "add x~D, x~D, :lo12:~A" d d (ir:symbol-of i)))))
      ((string= form "ldr")
       (access e "ldr" (colour-of e (ir:dst i)) (first srcs) (mach:imm i)))
      ((string= form "str")
       (access e "str" (second srcs) (first srcs) (mach:imm i)))
      (t
       (let ((template (mach:form-template form)))
         (line e (apply #'format nil (second template)
                        (loop for key in (cddr template)
                              collect (ecase key
                                        (:d (format nil "x~D" (colour-of e (ir:dst i))))
                                        (:s0 (format nil "x~D" (first srcs)))
                                        (:s1 (format nil "x~D" (second srcs)))
                                        (:s2 (format nil "x~D" (third srcs)))
                                        (:imm (mach:imm i))
                                        (:sym (ir:symbol-of i)))))))))))

(defun registers-read (f)
  (let ((read (make-hash-table :test #'eql)))
    (dolist (b (ir:walk f) read)
      (dolist (phi (ir:block-phis b))
        (dolist (r (ir:phi-regs phi)) (setf (gethash r read) t)))
      (dolist (i (ir:block-instrs b))
        (dolist (r (ir:uses i)) (setf (gethash r read) t))))))

;; -- modules ------------------------------------------------------------------

(defun escape (text)
  "One character of a literal is one byte; write the ones `.ascii` cannot."
  (with-output-to-string (out)
    (loop for ch across text
          for n = (char-code ch)
          do (cond ((= n #x22) (write-string "\\\"" out))
                   ((= n #x5C) (write-string "\\\\" out))
                   ((<= #x20 n #x7E) (write-char ch out))
                   (t (format out "\\~3,'0O" n))))))

(defun emit-module (m)
  (let ((parts (list (list (format nil "~C.text" #\Tab)))))
    (flet ((put (&rest lines) (push lines parts)))
      (dolist (f (ir:module-funcs m))
        (push (emit-func (make-instance 'emitter :func f)) parts)
        (put ""))
      (when (ir:module-strings m)
        (put (format nil "~C.section .rodata" #\Tab))
        (loop for (symbol . text) in (ir:module-strings m)
              do (put (format nil "~C.p2align 3" #\Tab)
                      (format nil "~A:" symbol)
                      (format nil "~C.quad ~D" #\Tab (length text))
                      (format nil "~C.ascii \"~A\"" #\Tab (escape text))
                      (format nil "~C.byte 0" #\Tab))))
      (put (format nil "~C.section .note.GNU-stack,\"\",%progbits" #\Tab)))
    (format nil "~{~A~^~%~}~%" (apply #'append (nreverse parts)))))

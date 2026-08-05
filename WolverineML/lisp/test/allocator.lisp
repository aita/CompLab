;;;; The allocator, the parallel copies, and what the emitter does with them.

(defpackage #:wolv.test.allocator
  (:use #:cl #:wolv.test)
  (:local-nicknames (#:alloc #:wolv.allocator) (#:copies #:wolv.copies)
                    (#:driver #:wolv.driver) (#:ir #:wolv.ir) (#:live #:wolv.liveness)
                    (#:low #:wolv.lower) (#:opt #:wolv.opt) (#:out #:wolv.outofssa)
                    (#:parser #:wolv.parser) (#:reg #:wolv.registers)
                    (#:sel #:wolv.select) (#:spill #:wolv.spill) (#:ssa #:wolv.ssa)
                    (#:types #:wolv.typecheck)))

(in-package #:wolv.test.allocator)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (setf *suite* "allocator"))

(defun lines (&rest parts) (format nil "~{~A~^~%~}~%" parts))

(defparameter *source*
  (lines "type point = { x : int, y : int }"
         ""
         "fun busy (n : int) : int ="
         "  let"
         "    var a = n + 1"
         "    var b = n + 2"
         "    var c = n + 3"
         "    var d = n + 4"
         "    var total = 0"
         "  in"
         "    while a < n * 10 do ("
         "      total := total + a * b + c * d;"
         "      a := a + 1;"
         "      b := b + 2;"
         "      c := c + 3;"
         "      d := d + 4"
         "    );"
         "    total"
         "  end"
         ""
         "fun caller (n : int) : int = busy (n) + busy (n + 1) + busy (n + 2)"
         ""
         "val p = point { x = 1, y = 2 }"
         "val () = printInt (caller (3) + p.x)"))

;; The pipeline up to the point where the allocator takes over.
(defun prepared (&optional (source *source*))
  (let ((prog (parser:parse source)))
    (types:check prog)
    (let ((m (low:lower prog (low:make-options t))))
      (ssa:construct-module m)
      (opt:optimise m)
      (dolist (f (ir:module-funcs m)) (ssa:split-critical-edges f))
      (sel:select-module m)
      (out:destruct-module m)
      m)))

(defun allocated (&optional (machine (reg:whole-machine)) (source *source*))
  (let ((m (prepared source)))
    (alloc:allocate-module m machine)
    m))

(defun instructions (f)
  (loop for b in (ir:walk f) append (ir:block-instrs b)))

(defun moves-left (m)
  (loop for f in (ir:module-funcs m)
        sum (loop for i in (instructions f)
                  count (and (typep i 'ir:i-move)
                             (not (eql (gethash (ir:dst i) (ir:func-colours f))
                                       (gethash (ir:src i) (ir:func-colours f))))))))

(defun colour-values (f)
  (loop for c being the hash-values of (ir:func-colours f) collect c))

;; -- what the colouring promises ----------------------------------------------

(deftest "every value gets a colour"
  (let ((m (allocated)))
    (dolist (f (ir:module-funcs m))
      (dolist (i (instructions f))
        (dolist (r (ir:uses i)) (is (gethash r (ir:func-colours f))))
        (when (ir:defs i) (is (gethash (ir:defs i) (ir:func-colours f))))))))

(deftest "values live together differ"
  (dolist (f (ir:module-funcs (allocated))) (alloc:verify f)))

(deftest "the verifier rejects a real clash"
  ;; One colour for everything is wrong, and has to be said so.  Without this,
  ;; weakening the verifier enough to accept a coalesced copy would go
  ;; unnoticed if it also stopped saying anything at all.
  (let ((m (allocated)))
    (dolist (f (ir:module-funcs m))
      (when (> (length (remove-duplicates (colour-values f))) 1)
        (let ((flattened (make-hash-table :test #'eql)))
          (loop for r being the hash-keys of (ir:func-colours f)
                do (setf (gethash r flattened) 0))
          (setf (ir:func-colours f) flattened)
          (signals error "at once" (alloc:verify f)))))))

(deftest "the verifier accepts a coalesced copy"
  ;; Both ends of a copy are live after it, and hold the same value.
  (let* ((f (ir:new-func "f" "f" 0))
         (entry (ir:add-block f "entry"))
         (a (ir:new-reg f))
         (b (ir:new-reg f)))
    (setf (ir:block-instrs entry)
          (list (ir:i-const a 1)
                (ir:i-move b a)
                (ir:i-call nil "wol_print_int" (list a))
                (ir:i-ret b)))
    (ir:recompute-preds f)
    (setf (gethash a (ir:func-colours f)) 9)
    (setf (gethash b (ir:func-colours f)) 9)
    (alloc:verify f)))

(deftest "a value live across a call is callee-saved"
  (let ((m (allocated)))
    (dolist (f (ir:module-funcs m))
      (dolist (r (live:across-calls f (live:analyse f)))
        (is (member (gethash r (ir:func-colours f)) reg:+callee-saved+))))))

(deftest "only the callee-saved it used are saved"
  (let ((m (allocated)))
    (dolist (f (ir:module-funcs m))
      (is= (sort (remove-duplicates
                  (remove-if-not (lambda (c) (member c reg:+callee-saved+))
                                 (colour-values f)))
                 #'<)
           (ir:func-saved f)))))

(deftest "a smaller machine still works"
  (dolist (size '(5 6 8 12 16 26))
    (let* ((machine (reg:limited size))
           (m (allocated machine)))
      (dolist (f (ir:module-funcs m))
        (alloc:verify f)
        (dolist (colour (colour-values f))
          (is (member colour (reg:anywhere machine))))))))

(deftest "a small machine spills"
  (let ((m (allocated (reg:limited 6))))
    (is (some (lambda (f) (plusp (hash-table-count (ir:func-spill-slots f))))
              (ir:module-funcs m))
        "nothing spilled")
    (dolist (f (ir:module-funcs m))
      (loop for slot being the hash-values of (ir:func-spill-slots f)
            do (is (< slot (ir:func-nslots f)))))))

(deftest "pressure falls to what the machine has"
  (let* ((machine (reg:limited 5))
         (m (allocated machine)))
    (dolist (f (ir:module-funcs m))
      (is (<= (live:pressure f (live:analyse f)) (reg:register-count machine))))))

(deftest "an impossible demand is reported"
  (let ((m (prepared
            (lines "fun ten (a : int, b : int, c : int, d : int, e : int,"
                   "         f : int, g : int, h : int, i : int, j : int) : int = a + j"
                   "val () = printInt (ten (1, 2, 3, 4, 5, 6, 7, 8, 9, 10))"))))
    (signals spill:out-of-registers "more registers"
      (alloc:allocate-module m (reg:limited 8)))))

;; -- what coalescing is for ---------------------------------------------------

(deftest "leaving SSA removes every phi"
  (dolist (f (ir:module-funcs (prepared)))
    (dolist (b (ir:walk f)) (is (null (ir:block-phis b))))))

(deftest "leaving SSA makes copies and coalescing eats them"
  (let* ((m (prepared))
         (before (loop for f in (ir:module-funcs m)
                       sum (count-if (lambda (i) (typep i 'ir:i-move)) (instructions f)))))
    (is (> before 0) "leaving SSA should have made copies")
    (alloc:allocate-module m (reg:whole-machine))
    (is (<= (moves-left m) (floor before 10))
        (format nil "~D of ~D copies survived" (moves-left m) before))))

;; -- parallel copies ----------------------------------------------------------

;; Run a parallel copy on a register file and insist the permutation came out
;; right.  This is what caught a swap the ordering was doing twice.
(defun perform (steps state)
  (dolist (step steps state)
    (etypecase step
      (copies:mov (setf (gethash (copies:mov-dst step) state)
                        (gethash (copies:mov-src step) state)))
      (copies:swap
       (let ((a (gethash (copies:swap-a step) state))
             (b (gethash (copies:swap-b step) state)))
         (setf (gethash (copies:swap-a step) state) b
               (gethash (copies:swap-b step) state) a))))))

(defun worked (moves borrowed)
  (let ((before (make-hash-table :test #'eql))
        (after (make-hash-table :test #'eql)))
    (dotimes (r 32)
      (setf (gethash r before) (format nil "v~D" r))
      (setf (gethash r after) (format nil "v~D" r)))
    (let ((steps (copies:sequentialize moves borrowed)))
      (perform steps after)
      (loop for (dst . src) in moves
            do (is= (gethash src before) (gethash dst after)
                    (format nil "x~D should hold v~D" dst src)))
      steps)))

(deftest "a copy with no cycle is just moves"
  (let ((steps (worked '((1 . 2) (3 . 4) (5 . 5)) 9)))
    (is (every (lambda (s) (typep s 'copies:mov)) steps))
    (is= 2 (length steps))))

(deftest "a chain is ordered so nothing is lost"
  (worked '((1 . 2) (2 . 3) (3 . 4)) 9))

(deftest "a cycle borrows a register when there is one"
  (let ((steps (worked '((1 . 2) (2 . 1)) 9)))
    (is (every (lambda (s) (typep s 'copies:mov)) steps))
    (is (some (lambda (s) (eql (copies:mov-dst s) 9)) steps))))

(deftest "a cycle swaps when there is nothing to borrow"
  (let ((steps (worked '((1 . 2) (2 . 1)) nil)))
    (is= 1 (length steps))
    (is (typep (first steps) 'copies:swap))))

(deftest "a longer cycle swaps its way round"
  (let ((steps (worked '((1 . 2) (2 . 3) (3 . 1)) nil)))
    (is (every (lambda (s) (typep s 'copies:swap)) steps))
    (is= 2 (length steps))))

(deftest "two cycles at once"
  (worked '((1 . 2) (2 . 1) (3 . 4) (4 . 3)) nil)
  (worked '((1 . 2) (2 . 1) (3 . 4) (4 . 3)) 9))

;; -- what the scratch registers used to be for --------------------------------

(deftest "the remainder is a divide and an msub"
  (let ((text (driver:compile-to-asm
               (lines "fun f (a : int, b : int) : int = a mod b"
                      "val () = printInt (f (7, 2))")
               (driver:default-options))))
    (is= 1 (count-if (lambda (l) (search "sdiv" l)) (split-lines text)))
    (is= 1 (count-if (lambda (l) (search "msub" l)) (split-lines text)))
    (is (notany (lambda (l) (search "mul" l)) (split-lines text)))))

(deftest "ordinary code keeps no register back"
  ;; x17 is only for an address the emitter cannot reach any other way.
  (let ((text (driver:compile-to-asm (read-file (tree-file "examples/tour.wol"))
                                     (driver:default-options))))
    (is (notany (lambda (l) (search "x17" l)) (split-lines text)))))

(deftest "x16 is allocatable"
  ;; It used to be held back for the emitter; a busy function should take it.
  (let ((text (driver:compile-to-asm (read-file (tree-file "test/programs/pressure.wol"))
                                     (driver:default-options))))
    (is (some (lambda (l) (search "x16" l)) (split-lines text)))))

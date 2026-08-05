;;;; Register allocation by graph colouring, with iterated coalescing.
;;;;
;;;; The idea is Chaitin's: build a graph whose nodes are values and whose
;;;; edges join values that are live at the same time, then colour it with as
;;;; many colours as the machine has registers.  Colouring a graph is hard in
;;;; general, but Kempe's observation makes it practical: a node with fewer
;;;; than K neighbours can always be coloured whatever happens to the rest of
;;;; the graph.  So remove such nodes one at a time and push them on a stack;
;;;; when the graph is empty, pop the stack and give each node a colour its
;;;; neighbours have not taken.  If every remaining node has K or more
;;;; neighbours, guess that one of them will not get a colour and carry on --
;;;; if the guess was wrong the value is rewritten to live in memory and the
;;;; whole thing runs again (Briggs' optimistic colouring).
;;;;
;;;; On top of that sits coalescing, which is why leaving SSA first costs
;;;; nothing.  Leaving SSA fills the predecessors of every join with copies;
;;;; coalescing merges the two ends of a copy so that it disappears.  Merging
;;;; aggressively can make a graph uncolourable, so a merge only happens when
;;;; Briggs' test proves it cannot: the merged node must have fewer than K
;;;; neighbours of significant degree.  That test is only exact enough to be
;;;; useful if degrees are up to date, and simplifying lowers degrees while
;;;; merging raises them -- so the two run interleaved, with freezing (giving
;;;; up on a copy so its nodes can be simplified) as the way out when neither
;;;; applies.  Hence "iterated" (George and Appel, 1996).
;;;;
;;;; This machine has no fixed registers to colour against, so the calling
;;;; convention is carried as a set of colours each node may not take: a value
;;;; live across a call may not take a caller-saved one.  A node with `f`
;;;; forbidden colours and `d` neighbours needs `d + f < K` to be trivially
;;;; colourable, so that sum is what stands in for the degree everywhere below.
;;;;
;;;; A hash table has no order, and every worklist here is one.  The order
;;;; matters -- which node is simplified first and which copy is looked at
;;;; first decide the colouring -- so every place that *chooses* goes through
;;;; `sorted` or `least`, and a colouring is the same twice.

(defpackage #:wolv.graph
  (:use #:cl)
  (:local-nicknames (#:ir #:wolv.ir)
                    (#:live #:wolv.liveness)
                    (#:hints #:wolv.hints)
                    (#:reg #:wolv.registers)
                    (#:rs #:wolv.regset)
                    (#:spill #:wolv.spill))
  (:export #:allocate))

(in-package #:wolv.graph)

;; -- sets of small integers, kept in a hash table and sorted when it counts ---

(defun mkset () (make-hash-table :test #'eql))
(defun has (s x) (gethash x s))
(defun add (s x) (setf (gethash x s) t))
(defun rm (s x) (remhash x s))
(defun any (s) (plusp (hash-table-count s)))
(defun sorted (s) (sort (loop for x being the hash-keys of s collect x) #'<))
(defun least (s) (reduce #'min (loop for x being the hash-keys of s collect x)))
(defun set-count* (s) (hash-table-count s))

(defclass colouring ()
  ((func :initarg :func :reader func)
   (machine :initarg :machine :reader machine)
   ;; Values a previous round produced by reloading something.  Their live
   ;; ranges are a load and its one use, so spilling one again would only make
   ;; another of the same, and the rewriting would never end.
   (protected :initarg :protected :reader protected)

   (adjacent :initform (make-hash-table :test #'eql) :reader adjacent-table)
   (degree :initform (make-hash-table :test #'eql) :reader degree-table)
   (forbidden :initform (make-hash-table :test #'eql) :reader forbidden-table)
   (preferred :initform (make-hash-table :test #'eql) :reader preferred)

   (moves :initform (make-array 0 :adjustable t :fill-pointer t) :reader moves)
   (moves-of :initform (make-hash-table :test #'eql) :reader moves-of)
   (worklist-moves :initform (mkset) :reader worklist-moves)
   (active-moves :initform (mkset) :reader active-moves)

   (simplify-worklist :initform (mkset) :reader simplify-worklist)
   (freeze-worklist :initform (mkset) :reader freeze-worklist)
   (spill-worklist :initform (mkset) :reader spill-worklist)
   (select-stack :initform '() :accessor select-stack)
   (on-stack :initform (mkset) :reader on-stack)
   (coalesced :initform (mkset) :reader coalesced)
   (alias :initform (make-hash-table :test #'eql) :reader alias)
   (colour :initform (make-hash-table :test #'eql) :reader colour)))

(defun k (c) (reg:register-count (machine c)))

(defun adjacent (c r) (gethash r (adjacent-table c)))
(defun forbidden (c r) (gethash r (forbidden-table c)))
(defun degree (c r) (gethash r (degree-table c)))

(defun weight (c r)
  "The degree, counting a forbidden colour as a neighbour holding it."
  (+ (degree c r) (set-count* (forbidden c r))))

;; -- colouring a function, for as long as it spills --------------------------

(defun allocate (f machine)
  (let ((protected (mkset)))
    (loop
      (ir:recompute-preds f)
      (let* ((c (make-instance 'colouring :func f :machine machine :protected protected))
             (spilled (run c)))
        (when (not (any spilled))
          (setf (ir:func-colours f) (colour c))
          (setf (ir:func-saved f)
                (sort (remove-duplicates
                       (loop for colour being the hash-values of (colour c)
                             when (member colour reg:+callee-saved+) collect colour))
                      #'<))
          (return))
        (dolist (victim (sorted spilled))
          (when (has protected victim)
            (error 'spill:out-of-registers
                   :message (format nil "`~A` needs more registers at once than the machine has"
                                    (ir:func-name f))))
          (dolist (reload (spill:spill f victim)) (add protected reload)))))))

(defun run (c)
  (build c)
  (make-worklists c)
  (loop while (or (any (simplify-worklist c)) (any (worklist-moves c))
                  (any (freeze-worklist c)) (any (spill-worklist c)))
        do (cond ((any (simplify-worklist c)) (simplify c))
                 ((any (worklist-moves c)) (coalesce c))
                 ((any (freeze-worklist c)) (freeze c))
                 (t (select-spill c))))
  (assign-colours c))

;; -- the graph ----------------------------------------------------------------

(defun node (c r)
  (unless (adjacent c r)
    (setf (gethash r (adjacent-table c)) (mkset))
    (setf (gethash r (degree-table c)) 0)
    (setf (gethash r (forbidden-table c)) (mkset))))

(defun add-edge (c a b)
  (unless (or (eql a b) (has (adjacent c a) b))
    (add (adjacent c a) b)
    (add (adjacent c b) a)
    (incf (gethash a (degree-table c)))
    (incf (gethash b (degree-table c)))))

(defun build (c)
  (let ((f (func c)))
    (loop for r being the hash-keys of (hints:preferences f) using (hash-value colour)
          do (setf (gethash r (preferred c)) colour))
    (let ((l (live:analyse f))
          (caller-saved (reg:machine-caller (machine c))))
      (dolist (b (ir:walk f))
        (dolist (i (ir:block-instrs b))
          (dolist (r (ir:uses i)) (node c r))
          (when (ir:defs i) (node c (ir:defs i)))))
      (dolist (r (ir:func-params f)) (node c r))

      (dolist (b (ir:walk f))
        (let ((alive (mkset)))
          (dolist (r (live:live-out l (ir:block-label b))) (add alive r))
          (dolist (i (reverse (ir:block-instrs b)))
            (when (typep i 'ir:i-move)
              (rm alive (ir:src i))
              (let ((index (fill-pointer (moves c))))
                (vector-push-extend (cons (ir:dst i) (ir:src i)) (moves c))
                (dolist (end (list (ir:dst i) (ir:src i)))
                  (add (or (gethash end (moves-of c))
                           (setf (gethash end (moves-of c)) (mkset)))
                       index))
                (add (worklist-moves c) index)))
            (let ((defined (ir:defs i)))
              (when defined
                (add alive defined)
                (dolist (other (sorted alive)) (add-edge c defined other)))
              ;; A value live across a call cannot sit in a caller-saved register.
              (when (typep i 'ir:i-call)
                (dolist (r (sorted alive))
                  (unless (eql r defined)
                    (dolist (col caller-saved) (add (forbidden c r) col)))))
              (when defined (rm alive defined))
              (dolist (r (ir:uses i)) (add alive r))))
          (when (string= (ir:block-label b) (ir:func-entry f))
            (entry-edges c alive)))))))

(defun entry-edges (c alive)
  "Parameters arrive together, so they interfere with each other."
  (let ((params (ir:func-params (func c))))
    (loop for tail on params
          for param = (first tail)
          do (dolist (other (sorted alive)) (add-edge c param other))
             (dolist (another (rest tail)) (add-edge c param another)))))

;; -- the worklists ------------------------------------------------------------

(defun make-worklists (c)
  (dolist (r (sort (loop for r being the hash-keys of (adjacent-table c) collect r) #'<))
    (cond ((>= (weight c r) (k c)) (add (spill-worklist c) r))
          ((move-related-p c r) (add (freeze-worklist c) r))
          (t (add (simplify-worklist c) r)))))

(defun node-moves (c r)
  (let ((mine (gethash r (moves-of c))))
    (when mine
      (loop for index in (sorted mine)
            when (or (has (active-moves c) index) (has (worklist-moves c) index))
              collect index))))

(defun move-related-p (c r) (and (node-moves c r) t))

(defun neighbours (c r)
  (loop for other in (sorted (adjacent c r))
        unless (or (has (on-stack c) other) (has (coalesced c) other))
          collect other))

(defun simplify (c)
  (let ((r (least (simplify-worklist c))))
    (rm (simplify-worklist c) r)
    (push r (select-stack c))
    (add (on-stack c) r)
    (dolist (other (neighbours c r)) (decrement-degree c other))))

(defun decrement-degree (c r)
  (let ((was (weight c r)))
    (decf (gethash r (degree-table c)))
    (when (= was (k c))
      ;; It has just become trivially colourable, so the copies around it may
      ;; have become safe to merge as well.
      (enable-moves c (append (neighbours c r) (list r)))
      (rm (spill-worklist c) r)
      (if (move-related-p c r)
          (add (freeze-worklist c) r)
          (add (simplify-worklist c) r)))))

(defun enable-moves (c nodes)
  (dolist (r nodes)
    (dolist (index (node-moves c r))
      (when (has (active-moves c) index)
        (rm (active-moves c) index)
        (add (worklist-moves c) index)))))

;; -- coalescing ---------------------------------------------------------------

(defun get-alias (c r)
  (loop while (has (coalesced c) r) do (setf r (gethash r (alias c))))
  r)

(defun coalesce (c)
  (let* ((index (least (worklist-moves c)))
         (move (aref (moves c) index)))
    (rm (worklist-moves c) index)
    (let ((u (get-alias c (car move)))
          (v (get-alias c (cdr move))))
      (cond
        ((eql u v) (add-to-worklist c u))
        ((has (adjacent c u) v) (add-to-worklist c u) (add-to-worklist c v))
        ((conservative-p c u v) (combine c u v) (add-to-worklist c u))
        (t (add (active-moves c) index))))))

(defun add-to-worklist (c r)
  (when (and (< (weight c r) (k c)) (not (move-related-p c r)))
    (rm (freeze-worklist c) r)
    (add (simplify-worklist c) r)))

(defun conservative-p (c u v)
  "Briggs: the merged node must have fewer than K significant neighbours.

The colours the two ends may not take add up as well, and a colour the merged
node is barred from is one more thing standing in its way."
  (let* ((together (rs:union (neighbours c u) (neighbours c v)))
         (barred (rs:count (rs:union (sorted (forbidden c u)) (sorted (forbidden c v)))))
         (significant (count-if (lambda (r) (>= (weight c r) (k c))) together)))
    (< (+ significant barred) (k c))))

(defun combine (c u v)
  (rm (freeze-worklist c) v)
  (rm (spill-worklist c) v)
  (add (coalesced c) v)
  (setf (gethash v (alias c)) u)
  (unless (gethash u (moves-of c)) (setf (gethash u (moves-of c)) (mkset)))
  (let ((theirs (gethash v (moves-of c))))
    (when theirs (dolist (index (sorted theirs)) (add (gethash u (moves-of c)) index))))
  (dolist (col (sorted (forbidden c v))) (add (forbidden c u) col))
  (when (and (gethash v (preferred c)) (not (gethash u (preferred c))))
    (setf (gethash u (preferred c)) (gethash v (preferred c))))
  (enable-moves c (list v))
  (dolist (other (neighbours c v))
    (add-edge c other u)
    (decrement-degree c other))
  (when (and (>= (weight c u) (k c)) (has (freeze-worklist c) u))
    (rm (freeze-worklist c) u)
    (add (spill-worklist c) u)))

;; -- freezing and spilling ----------------------------------------------------

(defun freeze (c)
  (let ((r (least (freeze-worklist c))))
    (rm (freeze-worklist c) r)
    (add (simplify-worklist c) r)
    (freeze-moves c r)))

(defun freeze-moves (c r)
  (dolist (index (node-moves c r))
    (let ((move (aref (moves c) index)))
      (rm (active-moves c) index)
      (rm (worklist-moves c) index)
      (let* ((end (if (eql (get-alias c (car move)) (get-alias c r))
                      (cdr move)
                      (car move)))
             (other (get-alias c end)))
        (when (and (not (move-related-p c other)) (< (weight c other) (k c)))
          (rm (freeze-worklist c) other)
          (add (simplify-worklist c) other))))))

(defun select-spill (c)
  "Guess that the value with the most neighbours per use will not fit.

Never a reload, though: those are cheap by that measure precisely because they
were made cheap, and choosing one would undo the last round's work instead of
the pressure."
  (let* ((weights (spill:costs (func c)))
         (unprotected (remove-if (lambda (r) (has (protected c) r))
                                 (sorted (spill-worklist c))))
         (among (or unprotected (sorted (spill-worklist c)))))
    (flet ((score (r) (/ (weight c r) (+ (gethash r weights 0d0) 1d0))))
      (let ((chosen (first among)))
        (dolist (r (rest among))
          (when (> (score r) (score chosen)) (setf chosen r)))
        (rm (spill-worklist c) chosen)
        (add (simplify-worklist c) chosen)
        (freeze-moves c chosen)))))

;; -- handing out the colours --------------------------------------------------

(defun assign-colours (c)
  (let ((spilled (mkset))
        (colours (colour c)))
    (loop while (select-stack c)
          do (let ((r (pop (select-stack c))))
               (rm (on-stack c) r)
               (let* ((taken (let ((s (mkset)))
                               (dolist (other (sorted (adjacent c r)) s)
                                 (let ((a (get-alias c other)))
                                   (when (gethash a colours)
                                     (add s (gethash a colours)))))))
                      (free (loop for candidate in (reg:anywhere (machine c))
                                  unless (or (has taken candidate)
                                             (has (forbidden c r) candidate))
                                    collect candidate)))
                 (if (null free)
                     (add spilled r)
                     (let ((want (gethash r (preferred c))))
                       (setf (gethash r colours)
                             (if (and want (member want free)) want (first free))))))))
    (dolist (r (sorted (coalesced c)))
      (setf (gethash r colours)
            (or (gethash (get-alias c r) colours) (first (reg:anywhere (machine c))))))
    spilled))

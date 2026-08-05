;;;; Random programs whose answer is known before they are compiled.
;;;;
;;;; The other tests say what the compiler should do; these say what the
;;;; program should print, which is the only thing a user cares about.  A
;;;; program is built at random, worked out here with the language's
;;;; arithmetic, and then compiled -- so any disagreement is a bug in the
;;;; compiler and not in a comparison between two of its own configurations.
;;;;
;;;; The generator carries its own linear congruential sequence rather than
;;;; using `random`, because a failing case has to be reachable again from its
;;;; seed and `*random-state*` is not promised to behave the same way twice.

(defpackage #:wolv.test.oracle
  (:use #:cl)
  (:local-nicknames (#:i64 #:wolv.i64))
  (:export #:arithmetic #:imperative))

(in-package #:wolv.test.oracle)

(defconstant +size+ 16)
(defparameter *vars* '("v0" "v1" "v2" "v3"))
(defparameter *constants*
  '(0 1 2 3 7 8 15 16 100 4095 4096 65536 -1 -8 1099511627776))
(defparameter *arguments*
  (list '(0 0 0) '(1 2 3) '(-1 7 -13)
        (list (1- (expt 2 63)) (- (expt 2 63)) 2)))
(defparameter *orders* '("=" "<>" "<" "<=" ">" ">="))

;; -- the source of chance -----------------------------------------------------

(defstruct (chance (:constructor chance (state)) (:copier nil)) state)

(defun next (g)
  (setf (chance-state g)
        (mod (+ (* 6364136223846793005 (chance-state g)) 1442695040888963407)
             (expt 2 64)))
  (ash (chance-state g) -33))

(defun below (g n) (mod (next g) n))
(defun roll (g) (/ (below g 1000) 1000.0d0))
(defun pick (g xs) (nth (below g (length xs)) xs))
(defun between (g lo hi) (+ lo (below g (1+ (- hi lo)))))

(defun weighted (g choices weights)
  "`+` twice as likely as `/`, because a division that turns out to be by zero
throws the whole expression away and generating them is not free."
  (let ((target (below g (reduce #'+ weights)))
        (seen 0))
    (loop for choice in choices
          for weight in weights
          do (when (< target (+ seen weight)) (return choice))
             (incf seen weight))))

;; -- the arithmetic half ------------------------------------------------------

(defun literal (value)
  (if (minusp value) (format nil "~~~D" (- value)) (format nil "~D" value)))

(defun expression (g depth)
  (cond
    ((or (zerop depth) (< (roll g) 0.25d0))
     (if (< (roll g) 0.5d0)
         (list :var (pick g '("a" "b" "c")))
         (list :int (pick g *constants*))))
    ((< (roll g) 0.1d0)
     (list :if (pick g *orders*)
           (expression g (1- depth)) (expression g (1- depth))
           (expression g (1- depth)) (expression g (1- depth))))
    (t
     (list :bin (weighted g '("+" "-" "*" "/" "mod") '(4 3 3 1 1))
           (expression g (1- depth)) (expression g (1- depth))))))

(define-condition divided-by-zero (error) ()
  (:documentation "The expression turned out to divide by zero; roll another."))

(defun compares (op a b)
  (cond ((string= op "=") (= a b))
        ((string= op "<>") (/= a b))
        ((string= op "<") (< a b))
        ((string= op "<=") (<= a b))
        ((string= op ">") (> a b))
        (t (>= a b))))

(defun evaluate (node env)
  (ecase (first node)
    (:var (cdr (assoc (second node) env :test #'string=)))
    (:int (second node))
    (:if (evaluate (if (compares (second node)
                                 (evaluate (third node) env)
                                 (evaluate (fourth node) env))
                       (fifth node)
                       (sixth node))
                   env))
    (:bin
     (let ((op (second node))
           (a (evaluate (third node) env))
           (b (evaluate (fourth node) env)))
       (cond ((string= op "+") (i64:add a b))
             ((string= op "-") (i64:sub a b))
             ((string= op "*") (i64:mul a b))
             ((zerop b) (error 'divided-by-zero))
             ((string= op "/") (i64:quot a b))
             (t (i64:remainder a b)))))))

(defun show (node)
  (ecase (first node)
    (:var (second node))
    (:int (literal (second node)))
    (:if (format nil "(if ~A ~A ~A then ~A else ~A)"
                 (show (third node)) (second node) (show (fourth node))
                 (show (fifth node)) (show (sixth node))))
    (:bin (format nil "(~A ~A ~A)" (show (third node)) (second node)
                  (show (fourth node))))))

(defun arithmetic (seed count)
  "COUNT functions of three arguments, and what they print."
  (let ((g (chance seed))
        (definitions '()) (calls '()) (expected '()) (made 0))
    (loop until (= made count)
          do (let* ((tree (expression g (between g 1 5)))
                    (values* (handler-case
                                 (loop for args in *arguments*
                                       collect (evaluate tree (pairlis '("a" "b" "c") args)))
                               (divided-by-zero () nil))))
               (when values*
                 (push (format nil "fun f~D (a : int, b : int, c : int) : int = ~A"
                               made (show tree))
                       definitions)
                 (loop for args in *arguments*
                       do (push (format nil "val () = (printInt (f~D (~{~A~^, ~})); print (\"\\n\"))"
                                        made (mapcar #'literal args))
                                calls))
                 (dolist (v values*) (push (format nil "~D" v) expected))
                 (incf made))))
    (values (format nil "~{~A~^~%~}~%"
                    (append (reverse definitions) (reverse calls)))
            (format nil "~{~A~^~%~}~%" (reverse expected)))))

;; -- the imperative half ------------------------------------------------------

(defun place (g scope)
  (let ((r (roll g)))
    (cond ((< r 0.35d0) (list :var (pick g scope)))
          ((< r 0.5d0) (list :int (pick g *constants*)))
          ((< r 0.65d0) (list :get (place g scope)))
          (t (list :bin (pick g '("+" "-" "*")) (place g scope) (place g scope))))))

(defun statement (g depth scope fresh)
  (let ((r (roll g)))
    (cond
      ((and (> depth 0) (< r 0.2d0))
       (list :if (pick g *orders*) (place g scope) (place g scope)
             (statement g (1- depth) scope fresh)
             (statement g (1- depth) scope fresh)))
      ((and (> depth 0) (< r 0.45d0))
       (incf (car fresh))
       (let ((name (format nil "i~D" (car fresh))))
         (list :for name (between g 0 2) (between g 2 5)
               (statement g (1- depth) (append scope (list name)) fresh))))
      ((and (> depth 0) (< r 0.55d0))
       (list :seq (list (statement g (1- depth) scope fresh)
                        (statement g (1- depth) scope fresh))))
      ((< r 0.8d0) (list :set (pick g *vars*) (place g scope)))
      (t (list :put (place g scope) (place g scope))))))

(defun cell (value)
  "`index` in the generated program: the remainder, made positive."
  (mod (+ (- value (* (i64:quot value +size+) +size+)) +size+) +size+))

(defun run-place (node env array)
  (ecase (first node)
    (:var (gethash (second node) env))
    (:int (second node))
    (:get (aref array (cell (run-place (second node) env array))))
    (:bin (let ((a (run-place (third node) env array))
                (b (run-place (fourth node) env array))
                (op (second node)))
            (cond ((string= op "+") (i64:add a b))
                  ((string= op "-") (i64:sub a b))
                  (t (i64:mul a b)))))))

(defun copy-env (env)
  (let ((fresh (make-hash-table :test #'equal)))
    (loop for k being the hash-keys of env using (hash-value v)
          do (setf (gethash k fresh) v))
    fresh))

(defun run-statement (node env array)
  "The environment is copied rather than mutated, because a `for` binds a
variable the loop above it does not have."
  (ecase (first node)
    (:set (let ((fresh (copy-env env)))
            (setf (gethash (second node) fresh) (run-place (third node) env array))
            fresh))
    (:put (setf (aref array (cell (run-place (second node) env array)))
                (run-place (third node) env array))
          env)
    (:seq (let ((env env))
            (dolist (item (second node) env)
              (setf env (run-statement item env array)))))
    (:if (let ((a (run-place (third node) env array))
               (b (run-place (fourth node) env array)))
           (run-statement (if (compares (second node) a b) (fifth node) (sixth node))
                          env array)))
    (:for (let ((env env))
            (loop for i from (third node) to (fourth node)
                  do (let ((inner (copy-env env)))
                       (setf (gethash (second node) inner) i)
                       (setf env (run-statement (fifth node) inner array))))
            env))))

(defun show-place (node)
  (ecase (first node)
    (:get (format nil "xs[index (~A)]" (show-place (second node))))
    (:bin (format nil "(~A ~A ~A)" (show-place (third node)) (second node)
                  (show-place (fourth node))))
    ((:var :int) (show node))))

(defun show-statement (node indent)
  (ecase (first node)
    (:set (format nil "~A~A := ~A" indent (second node) (show-place (third node))))
    (:put (format nil "~Axs[index (~A)] := ~A" indent (show-place (second node))
                  (show-place (third node))))
    (:seq (format nil "~A(~%~{~A~^;~%~}~%~A)" indent
                  (loop for i in (second node)
                        collect (show-statement i (concatenate 'string indent "  ")))
                  indent))
    (:if (format nil "~Aif ~A ~A ~A then~%~A~%~Aelse~%~A" indent
                 (show-place (third node)) (second node) (show-place (fourth node))
                 (show-statement (fifth node) (concatenate 'string indent "  "))
                 indent
                 (show-statement (sixth node) (concatenate 'string indent "  "))))
    (:for (format nil "~Afor ~A = ~D to ~D do~%~A" indent (second node)
                  (third node) (fourth node)
                  (show-statement (fifth node) (concatenate 'string indent "  "))))))

(defparameter *preamble*
  "val xs = array (16, 0)
fun index (n : int) : int =
  let val r = n - n / 16 * 16 in
    if r < 0 then r + 16 else r
  end
")

(defun imperative (seed count)
  "A program of assignments, loops and branches over an array."
  (let* ((g (chance seed))
         (body (loop repeat count collect (statement g 3 *vars* (list 0))))
         (array (make-array +size+ :initial-element 0))
         (env (make-hash-table :test #'equal)))
    (dolist (name *vars*) (setf (gethash name env) 0))
    (dolist (item body) (setf env (run-statement item env array)))
    (let ((expected (append (loop for name in *vars* collect (format nil "~D" (gethash name env)))
                            (loop for v across array collect (format nil "~D" v))))
          (lines (append (list *preamble*)
                         (loop for name in *vars* collect (format nil "var ~A = 0" name))
                         (list "val () = ("
                               (format nil "~{~A~^;~%~}"
                                       (loop for i in body collect (show-statement i "  ")))
                               ")")
                         (loop for name in *vars*
                               collect (format nil "val () = (printInt (~A); print (\"\\n\"))" name))
                         (list "val () = for k = 0 to 15 do (printInt (xs[k]); print (\"\\n\"))"))))
      (values (format nil "~{~A~^~%~}~%" lines)
              (format nil "~{~A~^~%~}~%" expected)))))

;;; Random programs whose answer is known before they are compiled.
;;;
;;; The other tests say what the compiler should do; these say what the program
;;; should print, which is the only thing a user cares about.  A program is
;;; built at random, worked out here with the language's arithmetic, and then
;;; compiled — so any disagreement is a bug in the compiler and not in a
;;; comparison between two of its own configurations.
;;;
;;; The generator carries its own linear congruential sequence rather than using
;;; Guile's `random`, because a failing case has to be reachable again from its
;;; seed and the state of the host's generator is not the sort of thing to rest
;;; that on.

(define-module (oracle)
  #:use-module (oop goops)
  #:use-module ((srfi srfi-1) #:select (first second third fourth fifth sixth
                                        fold delete-duplicates))
  #:use-module (ice-9 format)
  #:use-module (wolv i64)
  #:export (arithmetic imperative))

(define SIZE 16)
(define VARS '("v0" "v1" "v2" "v3"))
(define CONSTANTS '(0 1 2 3 7 8 15 16 100 4095 4096 65536 -1 -8 1099511627776))
(define ARGUMENTS
  (list '(0 0 0) '(1 2 3) '(-1 7 -13)
        (list (- (expt 2 63) 1) (- (expt 2 63)) 2)))
(define ORDERS '("=" "<>" "<" "<=" ">" ">="))

;; -- the source of chance ----------------------------------------------------

(define-class <chance> ()
  (state #:init-keyword #:state #:accessor chance-state))

(define (seeded seed) (make <chance> #:state seed))

(define (next g)
  (set! (chance-state g)
        (modulo (+ (* 6364136223846793005 (chance-state g)) 1442695040888963407)
                (expt 2 64)))
  (ash (chance-state g) -33))

(define (below g n) (modulo (next g) n))
(define (roll g) (/ (below g 1000) 1000.0))
(define (pick g xs) (list-ref xs (below g (length xs))))
(define (between g lo hi) (+ lo (below g (+ 1 (- hi lo)))))

;; `+` twice as likely as `/`, because a division that turns out to be by zero
;; throws the whole expression away and generating them is not free.
(define (weighted g choices weights)
  (let ((target (below g (fold + 0 weights))))
    (let loop ((choices choices) (weights weights) (seen 0))
      (if (< target (+ seen (first weights)))
          (first choices)
          (loop (cdr choices) (cdr weights) (+ seen (first weights)))))))

;; -- the arithmetic half -----------------------------------------------------

(define (literal value)
  (if (negative? value) (format #f "~~~a" (- value)) (number->string value)))

(define (expression g depth)
  (cond
   ((or (zero? depth) (< (roll g) 0.25))
    (if (< (roll g) 0.5)
        (list 'var (pick g '("a" "b" "c")))
        (list 'int (pick g CONSTANTS))))
   ((< (roll g) 0.1)
    (list 'if (pick g ORDERS)
          (expression g (- depth 1)) (expression g (- depth 1))
          (expression g (- depth 1)) (expression g (- depth 1))))
   (else
    (list 'bin (weighted g '("+" "-" "*" "/" "mod") '(4 3 3 1 1))
          (expression g (- depth 1)) (expression g (- depth 1))))))

;; Thrown when a generated expression turns out to divide by zero; the caller
;; throws that expression away and rolls another.
(define (divided-by-zero) (throw 'divided-by-zero))

(define (evaluate node env)
  (case (first node)
    ((var) (cdr (assoc (second node) env)))
    ((int) (second node))
    ((if) (evaluate (if (compares (second node)
                                  (evaluate (third node) env)
                                  (evaluate (fourth node) env))
                        (fifth node)
                        (sixth node))
                    env))
    (else
     (let ((op (second node))
           (a (evaluate (third node) env))
           (b (evaluate (fourth node) env)))
       (cond
        ((string=? op "+") (i64+ a b))
        ((string=? op "-") (i64- a b))
        ((string=? op "*") (i64* a b))
        ((zero? b) (divided-by-zero))
        ((string=? op "/") (i64-quotient a b))
        (else (i64-remainder a b)))))))

(define (compares op a b)
  (cond
   ((string=? op "=") (= a b))
   ((string=? op "<>") (not (= a b)))
   ((string=? op "<") (< a b))
   ((string=? op "<=") (<= a b))
   ((string=? op ">") (> a b))
   (else (>= a b))))

(define (show node)
  (case (first node)
    ((var) (second node))
    ((int) (literal (second node)))
    ((if) (format #f "(if ~a ~a ~a then ~a else ~a)" (show (third node)) (second node)
                  (show (fourth node)) (show (fifth node)) (show (sixth node))))
    (else (format #f "(~a ~a ~a)" (show (third node)) (second node)
                  (show (fourth node))))))

;; `count` functions of three arguments, and what they print.
(define (arithmetic seed count)
  (let ((g (seeded seed)))
    (let build ((made 0) (definitions '()) (calls '()) (expected '()))
      (cond
       ((= made count)
        (values (string-append (string-join (append (reverse definitions)
                                                    (reverse calls))
                                            "\n")
                               "\n")
                (string-append (string-join (reverse expected) "\n") "\n")))
       (else
        (let* ((tree (expression g (between g 1 5)))
               (values*
                (catch 'divided-by-zero
                  (lambda ()
                    (map (lambda (args) (evaluate tree (map cons '("a" "b" "c") args)))
                         ARGUMENTS))
                  (lambda args #f))))
          (cond
           ((not values*) (build made definitions calls expected))
           (else
            (build (+ made 1)
                   (cons (format #f "fun f~a (a : int, b : int, c : int) : int = ~a"
                                 made (show tree))
                         definitions)
                   (append (reverse
                            (map (lambda (args)
                                   (format #f "val () = (printInt (f~a (~a)); print (\"\\n\"))"
                                           made (string-join (map literal args) ", ")))
                                 ARGUMENTS))
                           calls)
                   (append (reverse (map number->string values*)) expected))))))))))

;; -- the imperative half -----------------------------------------------------

(define (statement g depth scope fresh)
  (let ((r (roll g)))
    (cond
     ((and (> depth 0) (< r 0.2))
      (list 'if (pick g ORDERS) (place g scope) (place g scope)
            (statement g (- depth 1) scope fresh)
            (statement g (- depth 1) scope fresh)))
     ((and (> depth 0) (< r 0.45))
      (set-car! fresh (+ 1 (car fresh)))
      (let ((name (format #f "i~a" (car fresh))))
        (list 'for name (between g 0 2) (between g 2 5)
              (statement g (- depth 1) (append scope (list name)) fresh))))
     ((and (> depth 0) (< r 0.55))
      (list 'seq (list (statement g (- depth 1) scope fresh)
                       (statement g (- depth 1) scope fresh))))
     ((< r 0.8) (list 'set (pick g VARS) (place g scope)))
     (else (list 'put (place g scope) (place g scope))))))

;; An expression over the variables in scope and the array.
(define (place g scope)
  (let ((r (roll g)))
    (cond
     ((< r 0.35) (list 'var (pick g scope)))
     ((< r 0.5) (list 'int (pick g CONSTANTS)))
     ((< r 0.65) (list 'get (place g scope)))
     (else (list 'bin (pick g '("+" "-" "*")) (place g scope) (place g scope))))))

;; `index` in the generated program: the remainder, made positive.
(define (cell value)
  (modulo (+ (- value (* (i64-quotient value SIZE) SIZE)) SIZE) SIZE))

(define (run-place node env array)
  (case (first node)
    ((var) (cdr (assoc (second node) env)))
    ((int) (second node))
    ((get) (vector-ref array (cell (run-place (second node) env array))))
    (else
     (let ((a (run-place (third node) env array))
           (b (run-place (fourth node) env array))
           (op (second node)))
       (cond
        ((string=? op "+") (i64+ a b))
        ((string=? op "-") (i64- a b))
        (else (i64* a b)))))))

;; The environment is threaded rather than mutated, because a `for` binds a
;; variable that the loop above it does not have.
(define (bind env name value)
  (cons (cons name value) (filter (lambda (p) (not (equal? (car p) name))) env)))

(define (run-statement node env array)
  (case (first node)
    ((set) (bind env (second node) (run-place (third node) env array)))
    ((put)
     (vector-set! array (cell (run-place (second node) env array))
                  (run-place (third node) env array))
     env)
    ((seq) (fold (lambda (item env) (run-statement item env array))
                 env (second node)))
    ((if)
     (let ((a (run-place (third node) env array))
           (b (run-place (fourth node) env array)))
       (run-statement (if (compares (second node) a b) (fifth node) (sixth node))
                      env array)))
    (else
     (let loop ((i (third node)) (env env))
       (if (> i (fourth node))
           env
           (loop (+ i 1)
                 (run-statement (fifth node) (bind env (second node) i) array)))))))

(define (show-place node)
  (case (first node)
    ((get) (format #f "xs[index (~a)]" (show-place (second node))))
    ((bin) (format #f "(~a ~a ~a)" (show-place (third node)) (second node)
                   (show-place (fourth node))))
    (else (show node))))

(define (show-statement node indent)
  (case (first node)
    ((set) (format #f "~a~a := ~a" indent (second node) (show-place (third node))))
    ((put) (format #f "~axs[index (~a)] := ~a" indent (show-place (second node))
                   (show-place (third node))))
    ((seq)
     (format #f "~a(\n~a\n~a)" indent
             (string-join (map (lambda (i)
                                 (show-statement i (string-append indent "  ")))
                               (second node))
                          ";\n")
             indent))
    ((if)
     (format #f "~aif ~a ~a ~a then\n~a\n~aelse\n~a" indent (show-place (third node))
             (second node) (show-place (fourth node))
             (show-statement (fifth node) (string-append indent "  "))
             indent (show-statement (sixth node) (string-append indent "  "))))
    (else
     (format #f "~afor ~a = ~a to ~a do\n~a" indent (second node) (third node)
             (fourth node)
             (show-statement (fifth node) (string-append indent "  "))))))

(define PREAMBLE
  (string-append
   "val xs = array (16, 0)\n"
   "fun index (n : int) : int =\n"
   "  let val r = n - n / 16 * 16 in\n"
   "    if r < 0 then r + 16 else r\n"
   "  end\n"))

;; A program of assignments, loops and branches over an array.
(define (imperative seed count)
  (let* ((g (seeded seed))
         (body (map-in-order (lambda (_) (statement g 3 VARS (list 0))) (iota count)))
         (array (make-vector SIZE 0))
         (env (fold (lambda (item env) (run-statement item env array))
                    (map (lambda (name) (cons name 0)) VARS)
                    body))
         (expected (append (map (lambda (name)
                                  (number->string (cdr (assoc name env))))
                                VARS)
                           (map number->string (vector->list array))))
         (out (append (list PREAMBLE)
                      (map (lambda (name) (format #f "var ~a = 0" name)) VARS)
                      (list "val () = ("
                            (string-join (map (lambda (i) (show-statement i "  ")) body)
                                         ";\n")
                            ")")
                      (map (lambda (name)
                             (format #f "val () = (printInt (~a); print (\"\\n\"))" name))
                           VARS)
                      (list "val () = for k = 0 to 15 do (printInt (xs[k]); print (\"\\n\"))"))))
    (values (string-append (string-join out "\n") "\n")
            (string-append (string-join expected "\n") "\n"))))

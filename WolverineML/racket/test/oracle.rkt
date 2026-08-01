#lang racket/base

;; Random programs whose answer is known before they are compiled.
;;
;; The other tests say what the compiler should do; these say what the program
;; should print, which is the only thing a user cares about.  A program is built
;; at random, worked out here with the language's arithmetic, and then compiled —
;; so any disagreement is a bug in the compiler and not in a comparison between
;; two of its own configurations.

(require racket/list
         racket/string
         "../src/i64.rkt")

(provide arithmetic imperative)

(define SIZE 16)
(define VARS '("v0" "v1" "v2" "v3"))
(define CONSTANTS '(0 1 2 3 7 8 15 16 100 4095 4096 65536 -1 -8 1099511627776))
(define ARGUMENTS
  (list '(0 0 0) '(1 2 3) '(-1 7 -13)
        (list (sub1 (expt 2 63)) (- (expt 2 63)) 2)))
(define ORDERS '("=" "<>" "<" "<=" ">" ">="))

;; -- the source of chance ----------------------------------------------------

;; One generator, seeded, so that a failing case can be looked at again.
(define (seeded seed)
  (define g (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator g]) (random-seed seed))
  g)

(define (roll g) (random g))
(define (pick g xs) (list-ref xs (random (length xs) g)))
(define (between g lo hi) (+ lo (random (add1 (- hi lo)) g)))

;; `+` twice as likely as `/`, because a division that turns out to be by zero
;; throws the whole expression away and generating them is not free.
(define (weighted g choices weights)
  (define total (apply + weights))
  (define target (random total g))
  (let walk ([choices choices] [weights weights] [seen 0])
    (if (< target (+ seen (first weights)))
        (first choices)
        (walk (rest choices) (rest weights) (+ seen (first weights))))))

;; -- the arithmetic half -----------------------------------------------------

(define (literal value) (if (negative? value) (format "~~~a" (- value)) (number->string value)))

(define (expression g depth)
  (cond
    [(or (zero? depth) (< (roll g) 0.25))
     (if (< (roll g) 0.5) (list 'var (pick g '("a" "b" "c"))) (list 'int (pick g CONSTANTS)))]
    [(< (roll g) 0.1)
     (list 'if (pick g ORDERS)
           (expression g (sub1 depth)) (expression g (sub1 depth))
           (expression g (sub1 depth)) (expression g (sub1 depth)))]
    [else
     (list 'bin (weighted g '("+" "-" "*" "/" "mod") '(4 3 3 1 1))
           (expression g (sub1 depth)) (expression g (sub1 depth)))]))

;; Raised when a generated expression turns out to divide by zero; the caller
;; throws that expression away and rolls another.
(struct divided-by-zero ())

(define (evaluate node env)
  (case (first node)
    [(var) (cdr (assoc (second node) env))]
    [(int) (second node)]
    [(if) (evaluate (if (compares (second node) (evaluate (third node) env)
                                  (evaluate (fourth node) env))
                        (fifth node)
                        (sixth node))
                    env)]
    [else
     (define op (second node))
     (define a (evaluate (third node) env))
     (define b (evaluate (fourth node) env))
     (cond
       [(string=? op "+") (i64+ a b)]
       [(string=? op "-") (i64- a b)]
       [(string=? op "*") (i64* a b)]
       [(zero? b) (raise (divided-by-zero))]
       [(string=? op "/") (i64-quotient a b)]
       [else (i64-remainder a b)])]))

(define (compares op a b)
  (cond
    [(string=? op "=") (= a b)]
    [(string=? op "<>") (not (= a b))]
    [(string=? op "<") (< a b)]
    [(string=? op "<=") (<= a b)]
    [(string=? op ">") (> a b)]
    [else (>= a b)]))

(define (show node)
  (case (first node)
    [(var) (second node)]
    [(int) (literal (second node))]
    [(if) (format "(if ~a ~a ~a then ~a else ~a)" (show (third node)) (second node)
                  (show (fourth node)) (show (fifth node)) (show (sixth node)))]
    [else (format "(~a ~a ~a)" (show (third node)) (second node) (show (fourth node)))]))

;; `count` functions of three arguments, and what they print.
(define (arithmetic seed count)
  (define g (seeded seed))
  (let build ([made 0] [definitions '()] [calls '()] [expected '()])
    (cond
      [(= made count)
       (values (string-append (string-join (append (reverse definitions) (reverse calls)) "\n")
                              "\n")
               (string-append (string-join (reverse expected) "\n") "\n"))]
      [else
       (define tree (expression g (between g 1 5)))
       (define values*
         (with-handlers ([divided-by-zero? (λ (e) #f)])
           (for/list ([args (in-list ARGUMENTS)])
             (evaluate tree (map cons '("a" "b" "c") args)))))
       (cond
         [(not values*) (build made definitions calls expected)]
         [else
          (build (add1 made)
                 (cons (format "fun f~a (a : int, b : int, c : int) : int = ~a"
                               made (show tree))
                       definitions)
                 (append (reverse
                          (for/list ([args (in-list ARGUMENTS)])
                            (format "val () = (printInt (f~a (~a)); print (\"\\n\"))"
                                    made (string-join (map literal args) ", "))))
                         calls)
                 (append (reverse (map number->string values*)) expected))])])))

;; -- the imperative half -----------------------------------------------------

(define (statement g depth scope fresh)
  (define r (roll g))
  (cond
    [(and (> depth 0) (< r 0.2))
     (list 'if (pick g ORDERS) (place g scope) (place g scope)
           (statement g (sub1 depth) scope fresh)
           (statement g (sub1 depth) scope fresh))]
    [(and (> depth 0) (< r 0.45))
     (set-box! fresh (add1 (unbox fresh)))
     (define name (format "i~a" (unbox fresh)))
     (list 'for name (between g 0 2) (between g 2 5)
           (statement g (sub1 depth) (append scope (list name)) fresh))]
    [(and (> depth 0) (< r 0.55))
     (list 'seq (list (statement g (sub1 depth) scope fresh)
                      (statement g (sub1 depth) scope fresh)))]
    [(< r 0.8) (list 'set (pick g VARS) (place g scope))]
    [else (list 'put (place g scope) (place g scope))]))

;; An expression over the variables in scope and the array.
(define (place g scope)
  (define r (roll g))
  (cond
    [(< r 0.35) (list 'var (pick g scope))]
    [(< r 0.5) (list 'int (pick g CONSTANTS))]
    [(< r 0.65) (list 'get (place g scope))]
    [else (list 'bin (pick g '("+" "-" "*")) (place g scope) (place g scope))]))

;; `index` in the generated program: the remainder, made positive.
(define (cell value) (modulo (+ (- value (* (i64-quotient value SIZE) SIZE)) SIZE) SIZE))

(define (run-place node env array)
  (case (first node)
    [(var) (hash-ref env (second node))]
    [(int) (second node)]
    [(get) (vector-ref array (cell (run-place (second node) env array)))]
    [else
     (define a (run-place (third node) env array))
     (define b (run-place (fourth node) env array))
     (case (string->symbol (second node))
       [(+) (i64+ a b)] [(-) (i64- a b)] [else (i64* a b)])]))

;; The environment is threaded rather than mutated, because a `for` binds a
;; variable that the loop above it does not have.
(define (run-statement node env array)
  (case (first node)
    [(set) (hash-set env (second node) (run-place (third node) env array))]
    [(put)
     (vector-set! array (cell (run-place (second node) env array))
                  (run-place (third node) env array))
     env]
    [(seq) (for/fold ([env env]) ([item (in-list (second node))])
             (run-statement item env array))]
    [(if)
     (define a (run-place (third node) env array))
     (define b (run-place (fourth node) env array))
     (run-statement (if (compares (second node) a b) (fifth node) (sixth node)) env array)]
    [else
     (for/fold ([env env]) ([i (in-range (third node) (add1 (fourth node)))])
       (run-statement (fifth node) (hash-set env (second node) i) array))]))

(define (show-place node)
  (case (first node)
    [(get) (format "xs[index (~a)]" (show-place (second node)))]
    [(bin) (format "(~a ~a ~a)" (show-place (third node)) (second node)
                   (show-place (fourth node)))]
    [else (show node)]))

(define (show-statement node indent)
  (case (first node)
    [(set) (format "~a~a := ~a" indent (second node) (show-place (third node)))]
    [(put) (format "~axs[index (~a)] := ~a" indent (show-place (second node))
                   (show-place (third node)))]
    [(seq)
     (format "~a(\n~a\n~a)" indent
             (string-join (for/list ([i (in-list (second node))])
                            (show-statement i (string-append indent "  ")))
                          ";\n")
             indent)]
    [(if)
     (format "~aif ~a ~a ~a then\n~a\n~aelse\n~a" indent (show-place (third node))
             (second node) (show-place (fourth node))
             (show-statement (fifth node) (string-append indent "  "))
             indent (show-statement (sixth node) (string-append indent "  ")))]
    [else
     (format "~afor ~a = ~a to ~a do\n~a" indent (second node) (third node) (fourth node)
             (show-statement (fifth node) (string-append indent "  ")))]))

(define PREAMBLE #<<END
val xs = array (16, 0)
fun index (n : int) : int =
  let val r = n - n / 16 * 16 in
    if r < 0 then r + 16 else r
  end

END
  )

;; A program of assignments, loops and branches over an array.
(define (imperative seed count)
  (define g (seeded seed))
  (define body (for/list ([_ (in-range count)]) (statement g 3 VARS (box 0))))
  (define array (make-vector SIZE 0))
  (define env
    (for/fold ([env (for/hash ([name (in-list VARS)]) (values name 0))])
              ([item (in-list body)])
      (run-statement item env array)))
  (define expected
    (append (for/list ([name (in-list VARS)]) (number->string (hash-ref env name)))
            (for/list ([v (in-vector array)]) (number->string v))))
  (define lines
    (append (list PREAMBLE)
            (for/list ([name (in-list VARS)]) (format "var ~a = 0" name))
            (list "val () = ("
                  (string-join (for/list ([i (in-list body)]) (show-statement i "  ")) ";\n")
                  ")")
            (for/list ([name (in-list VARS)])
              (format "val () = (printInt (~a); print (\"\\n\"))" name))
            (list "val () = for k = 0 to 15 do (printInt (xs[k]); print (\"\\n\"))")))
  (values (string-append (string-join lines "\n") "\n")
          (string-append (string-join expected "\n") "\n")))

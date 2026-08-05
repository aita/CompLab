;;;; Lowering: the typed syntax tree becomes a control flow graph.
;;;;
;;;; Two things are worth knowing about this pass.
;;;;
;;;; It never builds a phi.  A variable written in two branches is written to
;;;; the same register twice, and `ssa` is what turns those two writes into one
;;;; phi.  Lowering only has to make sure a definition reaches every use, which
;;;; structured control flow does for free.
;;;;
;;;; It decides where a variable lives.  A variable the checker did not mark as
;;;; escaping becomes a register; one that escaped becomes a frame slot,
;;;; reached through `i-load-slot`/`i-store-slot` in its own function and
;;;; through a chain of static links from a nested one.
;;;;
;;;; `lower-exp` is a generic function, like the checker's `check-exp`, and it
;;;; answers with the register the expression left its value in, or `nil` for
;;;; the forms that leave nothing.

(defpackage #:wolv.lower
  (:use #:cl)
  (:local-nicknames (#:ast #:wolv.ast)
                    (#:ir #:wolv.ir)
                    (#:ty #:wolv.types))
  (:export #:options #:make-options #:options-checks #:lower))

(in-package #:wolv.lower)

(defstruct (options (:constructor make-options (&optional (checks t))) (:copier nil))
  (checks t))

(defclass lowerer ()
  ((opts :initarg :opts :reader opts)
   (module-of :initform (ir:make-module) :reader module-of)
   (string-symbols :initform (make-hash-table :test #'equal) :reader string-symbols))
  (:documentation "Owns what the whole module shares: string literals and the
function list."))

(defun intern-string (up text)
  (or (gethash text (string-symbols up))
      (let ((symbol (format nil ".Lstr~D" (hash-table-count (string-symbols up)))))
        (setf (gethash text (string-symbols up)) symbol)
        (ir:add-string (module-of up) symbol text)
        symbol)))

(defclass func-lowerer ()
  ((up :initarg :up :reader up)
   (opts :initarg :opts :reader opts)
   (func :initarg :func :reader func)
   (cur :accessor cur)
   (breaks :initform '() :accessor breaks)
   (counter :initform 0 :accessor counter)
   (has-children :initform nil :accessor has-children)))

(defun new-func-lowerer (up label name depth)
  (let* ((f (ir:new-func label name depth))
         (fl (make-instance 'func-lowerer :up up :opts (opts up) :func f)))
    (setf (cur fl) (ir:add-block f "entry"))
    (when (plusp depth)
      (setf (ir:func-static-link-slot f) (ir:new-slot f)))
    (setf (ir:module-funcs (module-of up))
          (nconc (ir:module-funcs (module-of up)) (list f)))
    fl))

;; -- block plumbing -----------------------------------------------------------

(defun fresh (fl hint)
  (incf (counter fl))
  (ir:add-block (func fl) (format nil "~A~D" hint (counter fl))))

(defun emit (fl instr)
  (setf (ir:block-instrs (cur fl))
        (nconc (ir:block-instrs (cur fl)) (list instr))))

(defun terminate (fl term)
  (emit fl term)
  (setf (cur fl) (fresh fl "dead")))

(defun jump (fl block)
  (terminate fl (ir:i-jmp (ir:block-label block))))

(defun branch (fl test yes no)
  (terminate fl (ir:i-cbr test (ir:block-label yes) (ir:block-label no))))

(defun reg (fl) (ir:new-reg (func fl)))

(defun constant (fl value)
  (let ((r (reg fl)))
    (emit fl (ir:i-const r value))
    r))

;; -- function bodies ----------------------------------------------------------

(defun lower (prog &optional (opts (make-options)))
  (let* ((up (make-instance 'lowerer :opts opts))
         (main (new-func-lowerer up "wol_main" "main" 0)))
    (lower-decls main (ast:program-decls prog))
    (terminate main (ir:i-ret nil))
    (finish main)
    (module-of up)))

(defun lower-function (up bind)
  (let* ((sym (ast:fun-bind-sym bind))
         (fl (new-func-lowerer up (ty:fun-sym-label sym) (ty:fun-sym-name sym)
                               (ty:fun-sym-depth sym)))
         (f (func fl)))
    (when (plusp (ir:func-depth f))
      (let ((link (reg fl)))
        (setf (ir:func-params f) (nconc (ir:func-params f) (list link)))
        (emit fl (ir:i-store-slot (ir:func-static-link-slot f) link))))
    (loop for psym in (ty:fun-sym-params sym)
          for index from (length (ir:func-params f))
          do (if (>= index ir:+argument-registers+)
                 (setf (ty:var-sym-escapes psym) t
                       (ty:var-sym-slot psym) (- (+ (- index ir:+argument-registers+) 1)))
                 (let ((r (reg fl)))
                   (setf (ir:func-params f) (nconc (ir:func-params f) (list r)))
                   (if (ty:var-sym-escapes psym)
                       (progn (setf (ty:var-sym-slot psym) (ir:new-slot f))
                              (emit fl (ir:i-store-slot (ty:var-sym-slot psym) r)))
                       (setf (ty:var-sym-reg psym) r)))))
    (let* ((value (lower-exp (ast:fun-bind-body bind) fl))
           (returns (not (typep (ty:fun-sym-result sym) 'ty:unit-type))))
      (terminate fl (ir:i-ret (if returns value nil))))
    (finish fl)))

(defun finish (fl)
  (ir:drop-unreachable (func fl))
  (drop-unused-static-link fl))

(defun drop-unused-static-link (fl)
  "A function nobody nests inside, and that never looks outward, keeps no
static link: the slot goes, and every later slot moves down one."
  (let* ((f (func fl))
         (slot (ir:func-static-link-slot f)))
    (when (or (minusp slot) (has-children fl))
      (return-from drop-unused-static-link))
    (when (loop for b in (ir:walk f)
                thereis (loop for i in (ir:block-instrs b)
                              thereis (and (typep i 'ir:i-load-slot)
                                           (= (ir:slot i) slot))))
      (return-from drop-unused-static-link))
    (dolist (b (ir:walk f))
      (setf (ir:block-instrs b)
            (loop for i in (ir:block-instrs b)
                  unless (and (typep i 'ir:i-store-slot) (= (ir:slot i) slot))
                    collect (progn
                              (when (and (typep i '(or ir:i-store-slot ir:i-load-slot))
                                         (> (ir:slot i) slot))
                                (decf (ir:slot i)))
                              i))))
    (decf (ir:func-nslots f))
    (setf (ir:func-static-link-slot f) -1)))

;; -- declarations -------------------------------------------------------------

(defun lower-decls (fl decls)
  (dolist (d decls) (lower-decl d fl)))

(ast:defwalk lower-decl (d fl)
  (type-decl () nil)

  (fun-decl (binds)
    (setf (has-children fl) t)
    (dolist (bind binds) (lower-function (up fl) bind)))

  (val-decl (init sym)
    (let ((value (lower-exp init fl)))
      (when (and sym (not (typep (ty:var-sym-ty sym) 'ty:unit-type)))
        (assert value)
        (bind-var fl sym value)))))

(defun bind-var (fl sym value)
  "Give a variable its home, and put the initial value in it."
  (if (ty:var-sym-escapes sym)
      (progn
        (setf (ty:var-sym-slot sym) (ir:new-slot (func fl)))
        (emit fl (ir:i-store-slot (ty:var-sym-slot sym) value)))
      (progn
        (setf (ty:var-sym-reg sym) (reg fl))
        (emit fl (ir:i-move (ty:var-sym-reg sym) value)))))

;; -- reaching variables and frames --------------------------------------------

(defun frame-at (fl depth)
  "A register holding the frame pointer of the function at DEPTH."
  (let ((r (reg fl))
        (f (func fl)))
    (when (= depth (ir:func-depth f))
      (emit fl (ir:i-frame-addr r))
      (return-from frame-at r))
    (emit fl (ir:i-load-slot r (ir:func-static-link-slot f)))
    (loop for here downfrom (1- (ir:func-depth f)) above depth
          do (let ((next (reg fl)))
               (emit fl (ir:i-load next r (ir:slot-offset 0)))
               (setf r next)))
    r))

(defun read-var (fl sym)
  (cond
    ((not (ty:var-sym-escapes sym)) (ty:var-sym-reg sym))
    ((= (ty:var-sym-depth sym) (ir:func-depth (func fl)))
     (let ((r (reg fl)))
       (emit fl (ir:i-load-slot r (ty:var-sym-slot sym)))
       r))
    (t
     (let* ((base (frame-at fl (ty:var-sym-depth sym)))
            (r (reg fl)))
       (emit fl (ir:i-load r base (ir:slot-offset (ty:var-sym-slot sym))))
       r))))

(defun write-var (fl sym value)
  (cond
    ((not (ty:var-sym-escapes sym)) (emit fl (ir:i-move (ty:var-sym-reg sym) value)))
    ((= (ty:var-sym-depth sym) (ir:func-depth (func fl)))
     (emit fl (ir:i-store-slot (ty:var-sym-slot sym) value)))
    (t
     (let ((base (frame-at fl (ty:var-sym-depth sym))))
       (emit fl (ir:i-store base (ir:slot-offset (ty:var-sym-slot sym)) value))))))

;; -- expressions --------------------------------------------------------------

(defun value-of (fl e)
  (let ((r (lower-exp e fl)))
    (assert r () "expected a value from ~A" (class-name (class-of e)))
    r))

(defun binop (fl op lhs rhs)
  (let ((r (reg fl)))
    (emit fl (ir:i-bin r op lhs rhs))
    r))

(defun compare (fl op lhs rhs)
  (let ((r (reg fl)))
    (emit fl (ir:i-cmp r op lhs rhs))
    r))

(defun call-runtime (fl name args)
  (let ((r (reg fl)))
    (emit fl (ir:i-call r name args))
    r))

(defun element-address (fl e)
  "The address of `a[i]`, without the length word the elements follow.

The selector turns this into one `add` with a shifted operand, and the word is
the load's displacement, so the two instructions that come out are the two the
machine has."
  (let ((base (value-of fl (ast:arr e)))
        (idx (value-of fl (ast:index e))))
    (check-not-nil fl base)
    (check-bounds fl base idx)
    (binop fl "+" base (binop fl "shl" idx (constant fl 3)))))

(ast:defwalk lower-exp (e fl)
  (expression () (error "unknown expression ~A" (class-name (class-of e))))

  (int-lit (value) (constant fl value))
  (bool-lit (value) (constant fl (if value 1 0)))
  (nil-lit () (constant fl 0))
  (unit-lit () nil)

  (str-lit (value)
    (let ((r (reg fl)))
      (emit fl (ir:i-str-const r (intern-string (up fl) value)))
      r))

  (var-ref (sym) (read-var fl sym))

  (neg-exp (operand)
    (let ((zero (constant fl 0)))
      (binop fl "-" zero (value-of fl operand))))

  (bin-exp (op lhs rhs)
    (let ((left (value-of fl lhs))
          (right (value-of fl rhs)))
      (cond
        ((string= op "^") (call-runtime fl "wol_concat" (list left right)))
        ((or (string= op "/") (string= op "mod"))
         (check-nonzero fl right)
         (if (string= op "/")
             (binop fl "/" left right)
             ;; The remainder is spelled out rather than left to the emitter: the
             ;; quotient it needs in between is a value like any other, and the
             ;; allocator can find it a register.  The emitter fuses the last two
             ;; back into one `msub`.
             (let* ((quotient (binop fl "/" left right))
                    (product (binop fl "*" quotient right)))
               (binop fl "-" left product))))
        ((member op '("+" "-" "*") :test #'string=) (binop fl op left right))
        ((typep (ast:ty lhs) 'ty:string-type)
         (let ((order (call-runtime fl "wol_string_cmp" (list left right))))
           (compare fl op order (constant fl 0))))
        (t (compare fl op left right)))))

  ;; `andalso` and `orelse` are branches, so the result needs a register.
  (logic-exp (op lhs rhs)
    (let ((result (reg fl))
          (rhs-block (fresh fl "logic"))
          (join (fresh fl "logicjoin")))
      (let ((left (value-of fl lhs)))
        (emit fl (ir:i-move result left))
        (if (string= op "andalso")
            (branch fl left rhs-block join)
            (branch fl left join rhs-block)))
      (setf (cur fl) rhs-block)
      (emit fl (ir:i-move result (value-of fl rhs)))
      (jump fl join)
      (setf (cur fl) join)
      result))

  (call-exp (args sym)
    (let ((builtin (ty:fun-sym-builtin sym)))
      (cond
        ((equal builtin "not")
         (binop fl "xor" (value-of fl (first args)) (constant fl 1)))
        ((equal builtin "array")
         (let* ((n (value-of fl (first args)))
                (init (value-of fl (second args))))
           (call-runtime fl "wol_array" (list n init))))
        ((equal builtin "length")
         (let ((arr (value-of fl (first args))))
           (check-not-nil fl arr)
           (let ((r (reg fl)))
             (emit fl (ir:i-load r arr 0))
             r)))
        (t
         (let ((values (loop for a in args collect (value-of fl a))))
           (unless builtin
             (setf values (cons (frame-at fl (1- (ty:fun-sym-depth sym))) values)))
           (if (typep (ty:fun-sym-result sym) 'ty:unit-type)
               (progn (emit fl (ir:i-call nil (ty:fun-sym-label sym) values)) nil)
               (call-runtime fl (ty:fun-sym-label sym) values)))))))

  (record-lit (fields)
    (let* ((rec (ast:ty e))
           (size (constant fl (* ir:+word+ (max (length (ty:fields rec)) 1))))
           (base (call-runtime fl "wol_alloc" (list size))))
      (loop for f in fields
            for i from 0
            do (emit fl (ir:i-store base (* ir:+word+ i)
                                    (value-of fl (ast:field-init-value f)))))
      base))

  (index-exp ()
    (let ((addr (element-address fl e))
          (r (reg fl)))
      (emit fl (ir:i-load r addr ir:+word+))
      r))

  (field-exp (record offset)
    (let ((base (value-of fl record)))
      (check-not-nil fl base)
      (let ((r (reg fl)))
        (emit fl (ir:i-load r base (* ir:+word+ offset)))
        r)))

  (assign-exp (target value)
    (etypecase target
      (ast:var-ref (write-var fl (ast:sym target) (value-of fl value)))
      (ast:index-exp
       (let ((addr (element-address fl target)))
         (emit fl (ir:i-store addr ir:+word+ (value-of fl value)))))
      (ast:field-exp
       (let ((base (value-of fl (ast:record target))))
         (check-not-nil fl base)
         (emit fl (ir:i-store base (* ir:+word+ (ast:offset target))
                              (value-of fl value))))))
    nil)

  (if-exp (test then els)
    (let* ((wants-value (not (typep (ast:ty e) 'ty:unit-type)))
           (result (when wants-value (reg fl)))
           (yes (fresh fl "then"))
           (no (fresh fl "else"))
           (join (fresh fl "join")))
      (branch fl (value-of fl test) yes no)

      (setf (cur fl) yes)
      (let ((value (lower-exp then fl)))
        (when (and result value) (emit fl (ir:i-move result value))))
      (jump fl join)

      (setf (cur fl) no)
      (when els
        (let ((value (lower-exp els fl)))
          (when (and result value) (emit fl (ir:i-move result value)))))
      (jump fl join)

      (setf (cur fl) join)
      result))

  (while-exp (test body)
    (let ((test-block (fresh fl "test"))
          (body-block (fresh fl "body"))
          (done (fresh fl "done")))
      (jump fl test-block)
      (setf (cur fl) test-block)
      (branch fl (value-of fl test) body-block done)
      (setf (cur fl) body-block)
      (push (ir:block-label done) (breaks fl))
      (lower-exp body fl)
      (pop (breaks fl))
      (jump fl test-block)
      (setf (cur fl) done)
      nil))

  ;; `for i = lo to hi` counts up, and stops before overflowing at `hi`.
  (for-exp (lo hi body sym)
    (let* ((from (value-of fl lo))
           (to-value (value-of fl hi))
           (to (reg fl)))
      (emit fl (ir:i-move to to-value))
      (bind-var fl sym from)
      (let ((body-block (fresh fl "forbody"))
            (bump (fresh fl "forstep"))
            (done (fresh fl "fordone")))
        (branch fl (compare fl "<=" from to) body-block done)

        (setf (cur fl) body-block)
        (push (ir:block-label done) (breaks fl))
        (lower-exp body fl)
        (pop (breaks fl))
        (let ((i (read-var fl sym)))
          (branch fl (compare fl "<" i to) bump done))

        (setf (cur fl) bump)
        (write-var fl sym (binop fl "+" (read-var fl sym) (constant fl 1)))
        (jump fl body-block)

        (setf (cur fl) done)
        nil)))

  (break-exp ()
    (terminate fl (ir:i-jmp (first (breaks fl))))
    nil)

  (seq-exp (items)
    (let ((last nil))
      (dolist (item items last)
        (setf last (lower-exp item fl)))))

  (let-exp (decls body)
    (lower-decls fl decls)
    (lower-exp body fl)))

;; -- run-time checks ----------------------------------------------------------

(defun check-not-nil (fl base)
  (when (options-checks (opts fl))
    (let ((bad (fresh fl "nil"))
          (ok (fresh fl "ok")))
      (branch fl (compare fl "=" base (constant fl 0)) bad ok)
      (setf (cur fl) bad)
      (emit fl (ir:i-call nil "wol_nil_error" '()))
      (jump fl ok)
      (setf (cur fl) ok))))

(defun check-bounds (fl base idx)
  (when (options-checks (opts fl))
    (let ((length-reg (reg fl)))
      (emit fl (ir:i-load length-reg base 0))
      (let ((bad (fresh fl "oob"))
            (ok (fresh fl "ok")))
        (branch fl (compare fl "u<" idx length-reg) ok bad)
        (setf (cur fl) bad)
        (emit fl (ir:i-call nil "wol_bounds_error" (list idx length-reg)))
        (jump fl ok)
        (setf (cur fl) ok)))))

(defun check-nonzero (fl rhs)
  (when (options-checks (opts fl))
    (let ((bad (fresh fl "divzero"))
          (ok (fresh fl "ok")))
      (branch fl (compare fl "=" rhs (constant fl 0)) bad ok)
      (setf (cur fl) bad)
      (emit fl (ir:i-call nil "wol_div_error" '()))
      (jump fl ok)
      (setf (cur fl) ok))))

;;;; A Pratt parser.
;;;;
;;;; Every expression form is either a prefix form (in `atom`) or an infix one
;;;; (in `parse-exp`), and the table below is the whole of the precedence.  The
;;;; prefix forms that end in an expression -- `if`, `while`, `for`, `:=` --
;;;; take their tail at binding power 0, so `if c then x := 1 else x := 2`
;;;; reads the way it looks.

(defpackage #:wolv.parser
  (:use #:cl)
  (:local-nicknames (#:ast #:wolv.ast)
                    (#:diag #:wolv.diag)
                    (#:lex #:wolv.lexer))
  (:export #:parse #:parse-exp-string))

(in-package #:wolv.parser)

(defparameter *binding-powers*
  '((:assign 2 1)
    (:orelse 4 5)
    (:andalso 6 7)
    (:eq 8 9) (:ne 8 9) (:lt 8 9) (:le 8 9) (:gt 8 9) (:ge 8 9)
    (:caret 10 11)
    (:plus 12 13) (:minus 12 13)
    (:star 14 15) (:slash 14 15) (:mod 14 15)))

(defconstant +unary-bp+ 16)

(defparameter *binops*
  '((:plus . "+") (:minus . "-") (:star . "*") (:slash . "/") (:mod . "mod")
    (:caret . "^") (:eq . "=") (:ne . "<>") (:lt . "<") (:le . "<=")
    (:gt . ">") (:ge . ">=")))

(defparameter *decl-starters* '(:val :var :fun :type))

(defclass parser ()
  ((toks :initarg :toks :reader toks)
   (pos :initform 0 :accessor pos)))

;; -- token plumbing -----------------------------------------------------------

(defun cur (p) (aref (toks p) (pos p)))

(defun at-p (p kind) (eq (lex:token-kind (cur p)) kind))

(defun take (p kind)
  (when (at-p p kind)
    (prog1 (cur p) (incf (pos p)))))

(defun expect (p kind)
  (or (take p kind)
      (error 'diag:parse-error
             :span (lex:token-span (cur p))
             :message (format nil "expected `~A`, found ~A"
                              (lex:kind-text kind) (lex:token-description (cur p))))))

(defun expect-ident (p)
  (or (take p :ident)
      (error 'diag:parse-error
             :span (lex:token-span (cur p))
             :message (format nil "expected a name, found ~A"
                              (lex:token-description (cur p))))))

;; -- programs and declarations ------------------------------------------------

(defun program (p)
  (ast:make-program
   (loop until (at-p p :eof) collect (decl p))))

(defun decl (p)
  (case (lex:token-kind (cur p))
    (:type (type-decl p))
    ((:val :var) (val-decl p))
    (:fun (fun-decl p))
    (t (error 'diag:parse-error
              :span (lex:token-span (cur p))
              :message (format nil "expected a declaration (`val`, `var`, `fun`, `type`), found ~A"
                               (lex:token-description (cur p)))))))

(defun type-decl (p)
  (let ((span (lex:token-span (expect p :type))))
    (make-instance 'ast:type-decl :span span
                                  :binds (cons (type-bind p)
                                               (loop while (take p :and)
                                                     collect (type-bind p))))))

(defun type-bind (p)
  (let ((name (expect-ident p)))
    (expect p :eq)
    (ast:make-type-bind (lex:token-text name) (parse-ty p) (lex:token-span name))))

(defun val-decl (p)
  (let ((mutable (at-p p :var))
        (span (lex:token-span (cur p))))
    (incf (pos p))
    (let ((name (if (take p :lparen)
                    (progn (expect p :rparen) nil)
                    (lex:token-text (expect-ident p)))))
      (let ((ty (when (take p :colon) (parse-ty p))))
        (expect p :eq)
        (make-instance 'ast:val-decl :span span :name name :ty ty
                                     :init (parse-exp p 0) :mutable mutable)))))

(defun fun-decl (p)
  (let ((span (lex:token-span (expect p :fun))))
    (make-instance 'ast:fun-decl :span span
                                 :binds (cons (fun-bind p)
                                              (loop while (take p :and)
                                                    collect (fun-bind p))))))

(defun fun-bind (p)
  (let ((name (expect-ident p))
        (params '()))
    (expect p :lparen)
    (unless (take p :rparen)
      (loop (let ((pname (expect-ident p)))
              (expect p :colon)
              (push (ast:make-param (lex:token-text pname) (parse-ty p)
                                    (lex:token-span pname))
                    params))
            (unless (take p :comma) (return)))
      (expect p :rparen))
    (let ((result (when (take p :colon) (parse-ty p))))
      (expect p :eq)
      (ast:make-fun-bind (lex:token-text name) (nreverse params) result
                         (parse-exp p 0) (lex:token-span name)))))

;; -- types --------------------------------------------------------------------

(defun parse-ty (p)
  (let* ((span (lex:token-span (cur p)))
         (base
           (cond
             ((take p :lbrace)
              (let ((fields '()))
                (unless (take p :rbrace)
                  (loop (let ((fname (expect-ident p)))
                          (expect p :colon)
                          (push (ast:make-ty-field (lex:token-text fname) (parse-ty p)
                                                   (lex:token-span fname))
                                fields))
                        (unless (take p :comma) (return)))
                  (expect p :rbrace))
                (make-instance 'ast:ty-record :span span :fields (nreverse fields))))
             ((take p :lparen)
              (prog1 (parse-ty p) (expect p :rparen)))
             (t (make-instance 'ast:ty-name :span span
                                            :name (lex:token-text (expect-ident p)))))))
    (loop while (and (at-p p :ident) (string= (lex:token-text (cur p)) "array"))
          do (incf (pos p))
             (setf base (make-instance 'ast:ty-array :span span :elem base)))
    base))

;; -- expressions --------------------------------------------------------------

(defun parse-exp (p min-bp)
  (let ((left (atom-exp p)))
    (loop
      (let ((bp (assoc (lex:token-kind (cur p)) *binding-powers*)))
        (when (or (null bp) (< (second bp) min-bp)) (return left))
        (let ((tok (cur p)))
          (incf (pos p))
          (setf left
                (case (lex:token-kind tok)
                  (:assign
                   (check-lvalue left)
                   (make-instance 'ast:assign-exp :span (lex:token-span tok)
                                                  :target left
                                                  :value (parse-exp p (third bp))))
                  ((:andalso :orelse)
                   (make-instance 'ast:logic-exp :span (lex:token-span tok)
                                                 :op (lex:token-text tok) :lhs left
                                                 :rhs (parse-exp p (third bp))))
                  (t
                   (make-instance 'ast:bin-exp :span (lex:token-span tok)
                                               :op (cdr (assoc (lex:token-kind tok) *binops*))
                                               :lhs left
                                               :rhs (parse-exp p (third bp)))))))))))

(defun check-lvalue (e)
  (unless (typep e '(or ast:var-ref ast:index-exp ast:field-exp))
    (error 'diag:parse-error :span (ast:span e)
                             :message "the left of `:=` is not assignable")))

(defun atom-exp (p)
  (let* ((tok (cur p))
         (span (lex:token-span tok)))
    (case (lex:token-kind tok)
      (:int (incf (pos p))
            (postfix p (make-instance 'ast:int-lit :span span
                                                   :value (parse-integer (lex:token-text tok)))))
      (:string (incf (pos p))
               (postfix p (make-instance 'ast:str-lit :span span :value (lex:token-text tok))))
      ((:true :false) (incf (pos p))
                      (make-instance 'ast:bool-lit :span span
                                                   :value (eq (lex:token-kind tok) :true)))
      (:nil (incf (pos p)) (make-instance 'ast:nil-lit :span span))
      (:break (incf (pos p)) (make-instance 'ast:break-exp :span span))
      (:tilde (incf (pos p))
              (make-instance 'ast:neg-exp :span span :operand (parse-exp p +unary-bp+)))
      (:minus (error 'diag:parse-error :span span
                                       :message "negation is written `~`, not `-`"))
      (:lparen (postfix p (parens p)))
      (:ident (postfix p (named p)))
      (:if (if-exp p))
      (:while (while-exp p))
      (:for (for-exp p))
      (:let (let-exp p))
      (t (error 'diag:parse-error
                :span span
                :message (format nil "expected an expression, found ~A"
                                 (lex:token-description (cur p))))))))

(defun parens (p)
  (let ((span (lex:token-span (expect p :lparen))))
    (if (take p :rparen)
        (make-instance 'ast:unit-lit :span span)
        (let ((items (sequence-exps p :rparen)))
          (expect p :rparen)
          (if (null (rest items))
              (first items)
              (make-instance 'ast:seq-exp :span span :items items))))))

(defun sequence-exps (p end)
  (let ((items (list (parse-exp p 0))))
    (loop while (take p :semi)
          until (at-p p end)
          do (push (parse-exp p 0) items))
    (nreverse items)))

(defun named (p)
  (let ((tok (expect-ident p)))
    (case (lex:token-kind (cur p))
      (:lparen
       (incf (pos p))
       (let ((args '()))
         (unless (take p :rparen)
           (loop (push (parse-exp p 0) args)
                 (unless (take p :comma) (return)))
           (expect p :rparen))
         (make-instance 'ast:call-exp :span (lex:token-span tok)
                                      :name (lex:token-text tok) :args (nreverse args))))
      (:lbrace
       (incf (pos p))
       (let ((fields '()))
         (unless (take p :rbrace)
           (loop (let ((fname (expect-ident p)))
                   (expect p :eq)
                   (push (ast:make-field-init (lex:token-text fname) (parse-exp p 0)
                                              (lex:token-span fname))
                         fields))
                 (unless (take p :comma) (return)))
           (expect p :rbrace))
         (make-instance 'ast:record-lit :span (lex:token-span tok)
                                        :tyname (lex:token-text tok)
                                        :fields (nreverse fields))))
      (t (make-instance 'ast:var-ref :span (lex:token-span tok)
                                     :name (lex:token-text tok))))))

(defun postfix (p base)
  (loop
    (case (lex:token-kind (cur p))
      (:lbrack
       (let ((span (lex:token-span (cur p))))
         (incf (pos p))
         (let ((index (parse-exp p 0)))
           (expect p :rbrack)
           (setf base (make-instance 'ast:index-exp :span span :arr base :index index)))))
      (:dot
       (let ((span (lex:token-span (cur p))))
         (incf (pos p))
         (setf base (make-instance 'ast:field-exp :span span :record base
                                                  :name (lex:token-text (expect-ident p))))))
      (t (return base)))))

(defun if-exp (p)
  (let* ((span (lex:token-span (expect p :if)))
         (test (parse-exp p 0)))
    (expect p :then)
    (let* ((then (parse-exp p 0))
           (els (when (take p :else) (parse-exp p 0))))
      (make-instance 'ast:if-exp :span span :test test :then then :els els))))

(defun while-exp (p)
  (let* ((span (lex:token-span (expect p :while)))
         (test (parse-exp p 0)))
    (expect p :do)
    (make-instance 'ast:while-exp :span span :test test :body (parse-exp p 0))))

(defun for-exp (p)
  (let* ((span (lex:token-span (expect p :for)))
         (name (expect-ident p)))
    (expect p :eq)
    (let ((lo (parse-exp p 0)))
      (expect p :to)
      (let ((hi (parse-exp p 0)))
        (expect p :do)
        (make-instance 'ast:for-exp :span span :name (lex:token-text name)
                                    :lo lo :hi hi :body (parse-exp p 0))))))

(defun let-exp (p)
  (let ((span (lex:token-span (expect p :let)))
        (decls '()))
    (loop while (member (lex:token-kind (cur p)) *decl-starters*)
          do (push (decl p) decls))
    (expect p :in)
    (let ((body (if (at-p p :end)
                    (make-instance 'ast:unit-lit :span span)
                    (let ((items (sequence-exps p :end)))
                      (if (null (rest items))
                          (first items)
                          (make-instance 'ast:seq-exp :span span :items items))))))
      (expect p :end)
      (make-instance 'ast:let-exp :span span :decls (nreverse decls) :body body))))

;; -- the two entry points -----------------------------------------------------

(defun make-parser (source)
  (make-instance 'parser :toks (coerce (lex:lex source) 'vector)))

(defun parse (source)
  (program (make-parser source)))

(defun parse-exp-string (source)
  "Parse a single expression -- the tests use it, the compiler does not."
  (let* ((p (make-parser source))
         (e (parse-exp p 0)))
    (unless (at-p p :eof)
      (error 'diag:parse-error
             :span (lex:token-span (cur p))
             :message (format nil "unexpected ~A after the expression"
                              (lex:token-description (cur p)))))
    e))

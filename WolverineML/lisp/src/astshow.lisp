;;;; An indented dump of the typed syntax tree, for `wolv emit -s ast`.
;;;;
;;;; One method per node again, so that adding a form to the language is
;;;; adding a class and three methods and never editing a fourth thing.

(defpackage #:wolv.astshow
  (:use #:cl)
  (:local-nicknames (#:ast #:wolv.ast)
                    (#:ty #:wolv.types))
  (:export #:show-program #:quoted))

(in-package #:wolv.astshow)

(defun quoted (text)
  "A string literal, written the way the Python tree writes it, so that a dump
taken from either is the same dump.

Every character of one is a byte, and a byte that stands for nothing printable
is shown as `\\xNN`.  The other ports ask a Unicode database which bytes those
are; over the range a literal can hold -- U+0000 to U+00FF -- the answer is
four fixed ranges: the C0 and C1 controls, no-break space, and the soft
hyphen."
  (let ((quote-char (if (and (find #\' text) (not (find #\" text))) #\" #\')))
    (with-output-to-string (out)
      (write-char quote-char out)
      (loop for ch across text
            for n = (char-code ch)
            do (cond
                 ((or (char= ch quote-char) (char= ch #\\))
                  (write-char #\\ out) (write-char ch out))
                 ((= n 10) (write-string "\\n" out))
                 ((= n 13) (write-string "\\r" out))
                 ((= n 9) (write-string "\\t" out))
                 ((or (<= n #x1F) (<= #x7F n #xA0) (= n #xAD))
                  (format out "\\x~(~2,'0X~)" n))
                 (t (write-char ch out))))
      (write-char quote-char out))))

(defun put (stream depth text)
  (format stream "~vA~A~%" (* 2 depth) "" text))

(defun ty-suffix (e)
  (if (ast:ty e) (format nil " : ~A" (ty:type-text (ast:ty e))) ""))

(defun escapes-suffix (sym)
  (if (and sym (ty:var-sym-p sym) (ty:var-sym-escapes sym)) " (escapes)" ""))

(defun show-program (prog)
  (with-output-to-string (out)
    (dolist (d (ast:program-decls prog))
      (show-decl d 0 out))))

;; -- declarations -------------------------------------------------------------

(ast:defwalk show-decl (d depth stream)
  (type-decl (binds)
    (dolist (b binds)
      (put stream depth (format nil "type ~A" (ast:type-bind-name b)))))

  (val-decl (name mutable init sym)
    (put stream depth (format nil "~A ~A~A"
                              (if mutable "var" "val") (or name "()")
                              (escapes-suffix sym)))
    (show-exp init (1+ depth) stream))

  (fun-decl (binds)
    (dolist (f binds)
      (let ((params (format nil "~{~A~^, ~}"
                            (loop for p in (ast:fun-bind-params f)
                                  collect (format nil "~A~A" (ast:param-name p)
                                                  (escapes-suffix (ast:param-sym p))))))
            (result (if (ast:fun-bind-sym f)
                        (ty:type-text (ty:fun-sym-result (ast:fun-bind-sym f)))
                        "?")))
        (put stream depth
             (format nil "fun ~A(~A) : ~A" (ast:fun-bind-name f) params result))
        (show-exp (ast:fun-bind-body f) (1+ depth) stream)))))

;; -- expressions --------------------------------------------------------------

(ast:defwalk show-exp (e depth stream)
  (expression () (put stream depth "?"))

  (int-lit (value) (put stream depth (format nil "int ~D" value)))
  (str-lit (value) (put stream depth (format nil "string ~A" (quoted value))))
  (bool-lit (value) (put stream depth (format nil "bool ~A" (if value "true" "false"))))
  (nil-lit () (put stream depth "nil"))
  (unit-lit () (put stream depth "()"))
  (break-exp () (put stream depth "break"))

  (var-ref (name) (put stream depth (format nil "var ~A~A" name (ty-suffix e))))

  (call-exp (name args)
    (put stream depth (format nil "call ~A~A" name (ty-suffix e)))
    (dolist (a args) (show-exp a (1+ depth) stream)))

  (record-lit (tyname fields)
    (put stream depth (format nil "record ~A~A" tyname (ty-suffix e)))
    (dolist (f fields)
      (put stream (1+ depth) (format nil "~A =" (ast:field-init-name f)))
      (show-exp (ast:field-init-value f) (+ depth 2) stream)))

  (index-exp (arr index)
    (put stream depth (format nil "index~A" (ty-suffix e)))
    (show-exp arr (1+ depth) stream)
    (show-exp index (1+ depth) stream))

  (field-exp (record name)
    (put stream depth (format nil "field .~A~A" name (ty-suffix e)))
    (show-exp record (1+ depth) stream))

  (neg-exp (operand)
    (put stream depth "neg")
    (show-exp operand (1+ depth) stream))

  (bin-exp (op lhs rhs)
    (put stream depth (format nil "~A~A" op (ty-suffix e)))
    (show-exp lhs (1+ depth) stream)
    (show-exp rhs (1+ depth) stream))

  (logic-exp (op lhs rhs)
    (put stream depth (format nil "~A~A" op (ty-suffix e)))
    (show-exp lhs (1+ depth) stream)
    (show-exp rhs (1+ depth) stream))

  (assign-exp (target value)
    (put stream depth ":=")
    (show-exp target (1+ depth) stream)
    (show-exp value (1+ depth) stream))

  (if-exp (test then els)
    (put stream depth (format nil "if~A" (ty-suffix e)))
    (show-exp test (1+ depth) stream)
    (show-exp then (1+ depth) stream)
    (when els (show-exp els (1+ depth) stream)))

  (while-exp (test body)
    (put stream depth "while")
    (show-exp test (1+ depth) stream)
    (show-exp body (1+ depth) stream))

  (for-exp (name lo hi body sym)
    (put stream depth (format nil "for ~A~A" name (escapes-suffix sym)))
    (show-exp lo (1+ depth) stream)
    (show-exp hi (1+ depth) stream)
    (show-exp body (1+ depth) stream))

  (seq-exp (items)
    (put stream depth (format nil "seq~A" (ty-suffix e)))
    (dolist (item items) (show-exp item (1+ depth) stream)))

  (let-exp (decls body)
    (put stream depth (format nil "let~A" (ty-suffix e)))
    (dolist (d decls) (show-decl d (1+ depth) stream))
    (put stream depth "in")
    (show-exp body (1+ depth) stream)))

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

(defgeneric show-decl (decl depth stream))

(defmethod show-decl ((d ast:type-decl) depth stream)
  (dolist (b (ast:binds d))
    (put stream depth (format nil "type ~A" (ast:type-bind-name b)))))

(defmethod show-decl ((d ast:val-decl) depth stream)
  (put stream depth (format nil "~A ~A~A"
                            (if (ast:mutable d) "var" "val")
                            (or (ast:name d) "()")
                            (escapes-suffix (ast:sym d))))
  (show-exp (ast:init d) (1+ depth) stream))

(defmethod show-decl ((d ast:fun-decl) depth stream)
  (dolist (f (ast:binds d))
    (let ((params (format nil "~{~A~^, ~}"
                          (loop for p in (ast:fun-bind-params f)
                                collect (format nil "~A~A" (ast:param-name p)
                                                (escapes-suffix (ast:param-sym p))))))
          (result (if (ast:fun-bind-sym f)
                      (ty:type-text (ty:fun-sym-result (ast:fun-bind-sym f)))
                      "?")))
      (put stream depth (format nil "fun ~A(~A) : ~A" (ast:fun-bind-name f) params result))
      (show-exp (ast:fun-bind-body f) (1+ depth) stream))))

;; -- expressions --------------------------------------------------------------

(defgeneric show-exp (e depth stream))

(defmethod show-exp ((e ast:expression) depth stream) (put stream depth "?"))

(defmethod show-exp ((e ast:int-lit) depth stream)
  (put stream depth (format nil "int ~D" (ast:value e))))

(defmethod show-exp ((e ast:str-lit) depth stream)
  (put stream depth (format nil "string ~A" (quoted (ast:value e)))))

(defmethod show-exp ((e ast:bool-lit) depth stream)
  (put stream depth (format nil "bool ~A" (if (ast:value e) "true" "false"))))

(defmethod show-exp ((e ast:nil-lit) depth stream) (put stream depth "nil"))
(defmethod show-exp ((e ast:unit-lit) depth stream) (put stream depth "()"))

(defmethod show-exp ((e ast:var-ref) depth stream)
  (put stream depth (format nil "var ~A~A" (ast:name e) (ty-suffix e))))

(defmethod show-exp ((e ast:call-exp) depth stream)
  (put stream depth (format nil "call ~A~A" (ast:name e) (ty-suffix e)))
  (dolist (a (ast:args e)) (show-exp a (1+ depth) stream)))

(defmethod show-exp ((e ast:record-lit) depth stream)
  (put stream depth (format nil "record ~A~A" (ast:tyname e) (ty-suffix e)))
  (dolist (f (ast:fields e))
    (put stream (1+ depth) (format nil "~A =" (ast:field-init-name f)))
    (show-exp (ast:field-init-value f) (+ depth 2) stream)))

(defmethod show-exp ((e ast:index-exp) depth stream)
  (put stream depth (format nil "index~A" (ty-suffix e)))
  (show-exp (ast:arr e) (1+ depth) stream)
  (show-exp (ast:index e) (1+ depth) stream))

(defmethod show-exp ((e ast:field-exp) depth stream)
  (put stream depth (format nil "field .~A~A" (ast:name e) (ty-suffix e)))
  (show-exp (ast:record e) (1+ depth) stream))

(defmethod show-exp ((e ast:neg-exp) depth stream)
  (put stream depth "neg")
  (show-exp (ast:operand e) (1+ depth) stream))

(defmethod show-exp ((e ast:bin-exp) depth stream)
  (put stream depth (format nil "~A~A" (ast:op e) (ty-suffix e)))
  (show-exp (ast:lhs e) (1+ depth) stream)
  (show-exp (ast:rhs e) (1+ depth) stream))

(defmethod show-exp ((e ast:logic-exp) depth stream)
  (put stream depth (format nil "~A~A" (ast:op e) (ty-suffix e)))
  (show-exp (ast:lhs e) (1+ depth) stream)
  (show-exp (ast:rhs e) (1+ depth) stream))

(defmethod show-exp ((e ast:assign-exp) depth stream)
  (put stream depth ":=")
  (show-exp (ast:target e) (1+ depth) stream)
  (show-exp (ast:value e) (1+ depth) stream))

(defmethod show-exp ((e ast:if-exp) depth stream)
  (put stream depth (format nil "if~A" (ty-suffix e)))
  (show-exp (ast:test e) (1+ depth) stream)
  (show-exp (ast:then e) (1+ depth) stream)
  (when (ast:els e) (show-exp (ast:els e) (1+ depth) stream)))

(defmethod show-exp ((e ast:while-exp) depth stream)
  (put stream depth "while")
  (show-exp (ast:test e) (1+ depth) stream)
  (show-exp (ast:body e) (1+ depth) stream))

(defmethod show-exp ((e ast:for-exp) depth stream)
  (put stream depth (format nil "for ~A~A" (ast:name e) (escapes-suffix (ast:sym e))))
  (show-exp (ast:lo e) (1+ depth) stream)
  (show-exp (ast:hi e) (1+ depth) stream)
  (show-exp (ast:body e) (1+ depth) stream))

(defmethod show-exp ((e ast:break-exp) depth stream) (put stream depth "break"))

(defmethod show-exp ((e ast:seq-exp) depth stream)
  (put stream depth (format nil "seq~A" (ty-suffix e)))
  (dolist (item (ast:items e)) (show-exp item (1+ depth) stream)))

(defmethod show-exp ((e ast:let-exp) depth stream)
  (put stream depth (format nil "let~A" (ty-suffix e)))
  (dolist (d (ast:decls e)) (show-decl d (1+ depth) stream))
  (put stream depth "in")
  (show-exp (ast:body e) (1+ depth) stream))

;;; Source positions, and the one error every pass raises.
;;;
;;; Guile's way of raising something a caller can recognise is a throw with a
;;; key, so the key is `wolv` and the first argument is which pass threw it.  A
;;; test that wants a parse error catches `wolv` and looks at that argument;
;;; nothing has to define a condition type for it.

(define-module (wolv diag)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:export (<span> span span-line span-col show-span
            wolv-error lex-error parse-error type-error
            wolv-error-kind wolv-error-at wolv-error-message))

;; A position in the source, counted from one.
(define-class <span> ()
  (line #:init-keyword #:line #:getter span-line)
  (col #:init-keyword #:col #:getter span-col))

(define (span line col) (make <span> #:line line #:col col))

(define (show-span at) (format #f "~a:~a" (span-line at) (span-col at)))

;; The throw itself: `(wolv kind at message)`, where `kind` is lex, parse or
;; type so that a handler can ask for the one it means.
(define (wolv-error kind at template . arguments)
  (throw 'wolv kind at (apply format #f template arguments)))

(define (lex-error at template . arguments)
  (apply wolv-error 'lex at template arguments))

(define (parse-error at template . arguments)
  (apply wolv-error 'parse at template arguments))

(define (type-error at template . arguments)
  (apply wolv-error 'type at template arguments))

;; What a handler is handed, named rather than positional.
(define (wolv-error-kind kind at message) kind)
(define (wolv-error-at kind at message) at)
(define (wolv-error-message kind at message) message)

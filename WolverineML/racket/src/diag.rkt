#lang racket/base

;; Source positions, and the one error every pass raises.

(provide (struct-out span)
         (struct-out exn:wolv)
         show-span
         lex-error
         parse-error
         type-error)

;; A position in the source, counted from one.
(struct span (line col) #:transparent)

(define (show-span at)
  (format "~a:~a" (span-line at) (span-col at)))

;; `kind` is 'lex, 'parse or 'type, so a test can ask for the one it means.
(struct exn:wolv exn:fail (kind at) #:transparent)

(define (raise-wolv kind at template arguments)
  (raise (exn:wolv (format "~a: ~a" (show-span at) (apply format template arguments))
                   (current-continuation-marks)
                   kind
                   at)))

(define (lex-error at template . arguments) (raise-wolv 'lex at template arguments))
(define (parse-error at template . arguments) (raise-wolv 'parse at template arguments))
(define (type-error at template . arguments) (raise-wolv 'type at template arguments))

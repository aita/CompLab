;;;; Sets of registers, as sorted lists.
;;;;
;;;; Common Lisp has no set type, and the two obvious stand-ins are both wrong
;;;; here: a hash table has no order, and `union` on an ordinary list keeps
;;;; whichever order the arguments happened to have.  The order matters --
;;;; which value is looked at first decides a colouring, and a dump has to come
;;;; out the same twice -- so a set is a list that is sorted and has no
;;;; duplicates, every operation keeps it that way, and `equal` is set equality
;;;; for free.

(defpackage #:wolv.regset
  (:use #:cl)
  (:shadow #:union #:remove #:member #:adjoin #:set-difference #:count)
  (:export #:empty #:adjoin #:remove #:member #:union #:set-difference
           #:from-list #:to-list #:count #:emptyp #:same))

(in-package #:wolv.regset)

(defun empty () '())

(defun member (r set) (cl:member r set :test #'eql))

(defun adjoin (r set)
  (cond ((null set) (list r))
        ((< r (first set)) (cons r set))
        ((= r (first set)) set)
        (t (cons (first set) (adjoin r (rest set))))))

(defun remove (r set) (cl:remove r set :test #'eql))

(defun union (a b)
  (cond ((null a) b)
        ((null b) a)
        ((< (first a) (first b)) (cons (first a) (union (rest a) b)))
        ((> (first a) (first b)) (cons (first b) (union a (rest b))))
        (t (cons (first a) (union (rest a) (rest b))))))

(defun set-difference (a b)
  (cond ((null a) '())
        ((null b) a)
        ((< (first a) (first b)) (cons (first a) (set-difference (rest a) b)))
        ((> (first a) (first b)) (set-difference a (rest b)))
        (t (set-difference (rest a) (rest b)))))

(defun from-list (list) (sort (cl:remove-duplicates list) #'<))

(defun to-list (set) set)

(defun count (set) (length set))
(defun emptyp (set) (null set))
(defun same (a b) (equal a b))

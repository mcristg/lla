(in-package :lla)

(deftype symbol* () '(and symbol (not null)))
(defun symbolp* (object) (typep object 'symbol*))

;;;; this is missing from CFFI at the moment
(define-with-multiple-bindings with-foreign-pointer)

(defun ensure-vector (object)
  "Return object as a vector if possible, otherwise raise an error."
  (etypecase object
    (vector object)
    (number (vector object))))

(defun ensure-matrix (object &optional direction)
  "Return object as a matrix if possible, otherwise raise an error.  For
vectors, you need to specify the direction (:ROW or :COLUMN)."
  (etypecase object
    (number (make-array '(1 1) :initial-element object))
    (vector (displace-array object
                            (let ((l (length object)))
                              (ecase direction
                                (:row (list 1 l))
                                (:column (list l 1))))))
    ((array * (* *)) object)))


;; ;; #+sbcl (eval-when (:compile-toplevel :load-toplevel :execute)
;; ;;          (pushnew :muffle-notes cl:*features*))

;; (declaim (inline as-scalar%))
;; (defun as-scalar% (vector)
;;   "Pick the first element from a vector.  No checking."
;;   (row-major-aref vector 0))

;; ;;; muffling notes
;; (defmacro muffle-optimization-notes (&body body)
;;   "This macro silences compiler optimization notes."
;;   `(locally 
;;        #+sbcl (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
;;        ,@body))

;; (defun maybe-wrap-list (prefix body)
;;   "When PREFIX, wraps BODY in a list, starting with PREFIX, otherwise
;; return BODY.  Intended for use in macros."
;;   (if prefix
;;       (list (concatenate 'list prefix body))
;;       body))

;; (defun maybe-wrap (prefix &rest body)
;;   "When PREFIX, wraps BODY in a list, starting with PREFIX, otherwise
;; return BODY.  Intended for use in macros."
;;   (maybe-wrap-list prefix body))

;; ;;; array utilities

;; (declaim (inline zero-like))
;; (defun zero-like (array)
;;   "Return 0 coerced to the element type of ARRAY."
;;   (coerce 0 (array-element-type array)))

;; ;;; unfortunately, simple-vector is already taken by CL, for element
;; ;;; types T, so we define the new type SIMPLE-ARRAY1
;; (deftype simple-array1 (&optional element-type length)
;;   `(simple-array ,element-type (,length)))

;; (defun simple-array? (object)
;;   (typep object 'simple-array))

;; (defun simple-array1? (object)
;;   (typep object 'simple-array1))

;; (defun as-simple-array1 (array)
;;   "Return elements of ARRAY as a SIMPLE-ARRAY1.  Array is not
;; necessarily copied if it is already of the correct type."
;;   (etypecase array
;;     (simple-array1 array)
;;     (array (copy-seq (displace-array array (array-total-size array))))))

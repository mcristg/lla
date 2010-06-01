(in-package :lla)

(defstruct (elements%
             (:conc-name)
             (:constructor nil)         ; no constructor
             (:copier nil))
  "Structure which wraps elements.  Not for direct use, to be included
in other LLA classes."
  (elements nil :type simple-array1 :read-only t))

;;;  Matrix classes --- abstract interface
;;;
;;;  Being a subclass of DENSE-MATRIX essentially specifies a
;;;  storage model: elements are stored in column major format, and
;;;  the resulting vector can be passed to LAPACK.  See SET-RESTRICTED
;;;  and RESTRICTED-ELEMENTS for nuances.

(defstruct (dense-matrix-like 
             (:conc-name)
             (:constructor nil)
             (:copier nil)
             (:include elements%)
             (:print-object))
  "Superclass of all classes that resemble a matrix.
  Nevertheless, it is not implied that the elements should be
  interpreted as a matrix: they could be a matrix factorization packed
  into a matrix, etc.

  Subclasses of this class behave like an NROW x NCOL matrix, storing
  the elements in a subset of ELEMENTS, mapped using _column-major_
  indexing.  Specifically, the position of a particular element at
  index (row,col) row + NCOL*col, with 0 <= row < NROW and 0 <= col <
  NCOL.  The function CM-INDEX2 can be used for calculations.

  Not all elements are necessarily stored: some may be constants (eg
  for trianguar matrices), some may be inferred from other
  elements (eg for hermitian matrices).  When SET-RESTRICTED is
  called, it has to ensure that all values in ELEMENTS reflect the
  constant and/or inferred cells in the matrix."
  (nrow nil :type dimension :read-only t)
  (ncol nil :type dimension :read-only t))

;;;  Generic functions for element access

(defgeneric mref (matrix row col)
  (:documentation "Element accessor for matrices."))

(defgeneric (setf mref) (value matrix row col)
  (:documentation "Element accessor for matrices."))

(define-condition mref-setting-readonly (error)
  ()
  (:documentation "Trying to set a constant element."))

;;;  Square matrix type

(defun square-matrix? (matrix)
  "Test if a matrix is square."
  (= (nrow matrix) (ncol matrix)))

(deftype square-matrix ()
  '(and dense-matrix-like
    (satisfies square-matrix?)))

;;;  Matrix kind and class
;;;
;;;  Matrices have a _kind_, eg dense, lower, etc, with a bijection
;;;  between kinds and class names.  The following two functions
;;;  provide the framework for the mapping, and the macro defines them
;;;  automatically.

(defgeneric valid-matrix-kind? (kind)
  (:documentation "Return non-NIL if KIND is a valid matrix kind.")
  (:method (kind)
    nil))

(defgeneric matrix-type (kind)
  (:documentation "Return type for matrix kind."))

(defgeneric matrix-kind (matrix)
  (:documentation "Return the matrix kind, eg :DENSE, :UPPER, etc."))

(defmacro define-dense-matrix-like
    (kind documentation)
  "Macro for defining simple structures that inherit from DENSE-MATRIX-LIKE."
  (check-type kind symbol)
  (check-type documentation string)
  (let ((class (make-symbol% kind '#:-matrix))
        (kind (make-keyword kind))
        (constructor (make-symbol% '#:make- kind '#:-matrix%)))
    `(progn
       (defstruct (,class
             (:conc-name)
             (:constructor ,constructor (nrow ncol elements))
             (:copier nil)
             (:include dense-matrix-like)))
       ,documentation
       (defmethod matrix-kind ((matrix ,class)) ,kind)
       (defmethod valid-matrix-kind? ((kind (eql ,kind))) t)
       (defmethod matrix-type ((kind (eql ,kind))) ',class))))

;;; The four basic matrix types: dense, upper/lower (triangular) and
;;; hermitian.

(define-dense-matrix-like dense
    "A dense matrix.")

(define-dense-matrix-like upper
    "A dense, upper triangular matrix.  The elements below the
diagonal are not necessarily initialized and not accessed.")

(define-dense-matrix-like lower
    "A dense, lower triangular matrix.  The elements above the
diagonal are not necessarily initialized and not accessed.")

(define-dense-matrix-like hermitian
  ;; LLA uses the class HERMITIAN-MATRIX to implement both real
  ;; symmetric and complex Hermitian matrices --- as technically, real
  ;; symmetric matrices are also Hermitian.  Complex symmetric
  ;; matrices are NOT implemented as a special matrix type, as they
  ;; don't have any special properties (eg real eigenvalues, etc).
  "A dense Hermitian matrix, with elements stored in the upper
  triangle.")

;;; element mask query functions

(defgeneric matrix-mask (kind row col)
  (:documentation "Return NIL iff the element is not used in the dense
  representation of KIND for element (ROW,COL).")
  (:method ((kind (eql :dense)) row col)
    t)
  (:method ((kind (eql :upper)) row col)
    (<= row col))
  (:method ((kind (eql :lower)) row col)
    (>= row col))
  (:method ((kind (eql :hermitian)) row col)
    (<= row col)))

;;; Framework for dense matrices with restricted elements.

(defgeneric set-restricted (matrix)
  (:method ((matrix dense-matrix))
    ;; do nothing, return matrix
    matrix)
  (:documentation "Set restricted/unaccessed elements to the
appropriate value in the data vector of matrix.  Always return the
matrix.  Useful when calling functions which expect a proper dense
matrix."))

(defmethod set-restricted ((matrix upper-matrix))
  ;; set the lower triangle (below diagonal) to 0
  (declare (optimize speed (safety 0)))
  (bind (((:slots-r/o nrow ncol elements) matrix))
    (declare (fixnum nrow ncol))
    (with-vector-type-expansion (elements)
      (lambda (lla-type)
        `(let ((zero (zero* ,lla-type)))
           (declare (type ,(lla->lisp-type lla-type) zero))
           (dotimes (col ncol)
             (declare (fixnum col))
             (iter
               (declare (iterate:declare-variables))
               (for (the fixnum index)
                    :from (1+ (cm-index2 nrow col col))
                    :below (cm-index2 nrow nrow col))
               (setf (aref elements index) zero)))))))
  matrix)

(defmethod set-restricted ((matrix lower-matrix))
  ;; set the upper triangle (above diagonal) to 0
  (declare (optimize speed (safety 0)))
  (bind (((:slots-r/o nrow ncol elements) matrix))
    (declare (fixnum nrow ncol))
    (with-vector-type-expansion (elements)
      (lambda (lla-type)
        `(let ((zero (zero* ,lla-type)))
           (declare (type ,(lla->lisp-type lla-type) zero))
           (dotimes (col ncol)
             (declare (fixnum col))
             (iter
               (declare (iterate:declare-variables))
               (for (the fixnum index)
                    :from (cm-index2 nrow 0 col)
                    :below (cm-index2 nrow col col))
               (setf (aref elements index) zero)))))))
  matrix)

(defmethod set-restricted ((matrix hermitian-matrix))
  ;; set the lower triangle (below diagonal) to conjugate of the
  ;; elements in the upper triangle
  (declare (optimize speed (safety 0)))
  (bind (((:slots-r/o nrow ncol elements) matrix))
    (declare (fixnum nrow ncol))
    (with-vector-type-declarations (elements)
      (dotimes (col ncol)
        (declare (fixnum col))
        (iter
          (for (the fixnum row) :from col :below nrow)
          (for (the fixnum index)
               :from (cm-index2 nrow col col)
               :below (cm-index2 nrow nrow col))
          (declare (iterate:declare-variables))
          (muffle-optimization-notes
            (setf (aref elements index)
                  (conjugate (aref elements (cm-index2 nrow col row)))))))))
  matrix)


;;; mref for dense matrices

(defmethod mref ((matrix dense-matrix) row col)
  (bind (((:slots-r/o elements nrow ncol) matrix))
    (check-index row nrow)
    (check-index col ncol)
    (aref elements (cm-index2 nrow row col))))

(defmethod (setf mref) (value (matrix dense-matrix) row col)
  (bind (((:slots-r/o elements nrow ncol) matrix))
    (check-index row nrow)
    (check-index col ncol)
    (setf (aref elements (cm-index2 nrow row col))
          value)))


;;; mref for upper triangular matrices

(defmethod mref ((matrix upper-matrix) row col)
  (bind (((:slots-r/o elements nrow ncol) matrix))
    (check-index row nrow)
    (check-index col ncol)
    (if (<= row col)
        (aref elements (cm-index2 nrow row col))
        (zero-like elements))))

(defmethod (setf mref) (value (matrix upper-matrix) row col)
  (bind (((:slots-r/o elements nrow ncol) matrix))
    (check-index row nrow)
    (check-index col ncol)
    (if (<= row col)
        (setf (aref elements (cm-index2 nrow row col))
              value)
        (error 'mref-setting-readonly))))

;;; mref for lower triangular matrices

(defmethod mref ((matrix lower-matrix) row col)
  (bind (((:slots-r/o elements nrow ncol) matrix))
    (check-index row nrow)
    (check-index col ncol)
    (if (>= row col)
        (aref elements (cm-index2 nrow row col))
        (zero-like elements))))

(defmethod (setf mref) (value (matrix lower-matrix) row col)
  (bind (((:slots-r/o elements nrow ncol) matrix))
    (check-index row nrow)
    (check-index col ncol)
    (if (>= row col)
        (setf (aref elements (cm-index2 nrow row col)) value)
        (error 'mref-setting-readonly))))

;;; mref for hermitian matrices

(defmethod mref ((matrix hermitian-matrix) row col)
  (bind (((:slots-r/o elements nrow ncol) matrix))
    (check-index row nrow)
    (check-index col ncol)
    (if (<= row col)
        (aref elements (cm-index2 nrow row col))
        (conjugate (aref elements (cm-index2 nrow col row))))))

(defmethod (setf mref) (value (matrix hermitian-matrix) row col)
  (bind (((:slots-r/o elements nrow ncol) matrix))
    (check-index row nrow)
    (check-index col ncol)
    (if (<= row col)
        (setf (aref elements (cm-index2 nrow row col)) value)
        (setf (aref elements (cm-index2 nrow col row)) (conjugate value)))))

;;;; matrix creation

(defun check-matrix-dimensions% (nrow ncol length)
  "Check that NROW and NCOL are compatible with the length of
elements."
  (assert (= (* nrow ncol) length) ()
          "NROW and NCOL don't match ELEMENTS."))

(defun make-matrix% (nrow ncol elements &key (kind :dense))
  "Create a matrix with given ELEMENTS, TYPE, LLA-TYPE and dimensions.
Dimensions are checked agains length of ELEMENTS.  Note that elements
are not copied: this is effectively shorthand for a make-*-matrix%
call.  For internal use, not exported."
  (check-matrix-dimensions% nrow ncol (length elements))
  (ecase kind
    (:dense (make-dense-matrix% nrow ncol elements))
    (:lower (make-lower-matrix% nrow ncol elements))
    (:upper (make-upper-matrix% nrow ncol elements))
    (:hermitian 
       (assert (= nrow ncol) () "Hermitian matrix is not square.")
       (make-hermitian-matrix% nrow nrow elements))))

(defun make-matrix (lla-type nrow ncol &key (kind :dense) (initial-element 0))
  "Create a matrix with given parameters, optionally initialized with
INITIAL-ELEMENTs."
  (make-matrix% nrow ncol
                (lla-vector lla-type (* nrow ncol) (coerce* initial-element lla-type))
                :kind kind))

(defun copy-matrix (matrix &key (kind (matrix-kind matrix))
                    lla-type (copy? nil copy??)
                    (nrow (nrow matrix)) (ncol (ncol matrix)))
  "Copy or convert matrix to the given kind, converting if LLA-TYPE is
supplied.  It is a shallow copy unless LLA-TYPE is given or COPY? is
non-nil.  Important usage note: if you want a matrix with restricted
elements, it is advisable to set copy?, otherwise a call to
SET-RESTRICTED hidden somewhere might change the original matrix,
without your intention.  Therefore if kinds or shapes differ,
1. set-restricted is called on matrix, and 2. copy? defaults to T,
unless explicitly specified."
  (let ((default-copy? (not (and (eq kind (matrix-kind matrix))
                                 (or (eq kind :dense)
                                     (= (nrow matrix) nrow))))))
    (when default-copy?
      (set-restricted matrix))
    (make-matrix% nrow ncol
                  (maybe-copy-vector (elements matrix)
                                     (if copy?? copy? default-copy?)
                                     lla-type)
                  :kind kind)))

(defmethod pack ((matrix dense-matrix-like))
  (set-restricted matrix)
  (make-matrix% (nrow matrix) (ncol matrix) (pack (elements matrix))))

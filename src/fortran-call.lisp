;;; -*- Mode:Lisp; Syntax:ANSI-Common-Lisp; Coding:utf-8 -*-

(in-package #:lla)

;;; These macros take care of array pinning and the conversion of constants to pointers to an allocated memory area with the value so that everything is set up to call Fortran/BLAS/LAPACK functions.
;;;
;;; Since LAPACK functions are sometimes called two times (eg to query work area sizes), expansions take place in 'passes', such as
;;;
;;;  - BINDINGS: establishes the bindings (also empty variables)
;;;
;;;  - MAIN: for arguments that are the same regardless of what kind of call is made
;;;
;;;  - QUERY: for querying work area sizes
;;;
;;;  - CALL: the actual function call
;;;
;;; The DSL is implemented via macros which expand to structures, which are in then handed to WRAP-ARGUMENT for each pass.

;;;; generic interface and helper functions

(defgeneric process-form (form environment)
  (:documentation "Return a list of argument specifications (atoms are converted into lists).")
  (:method (form environment)
    (macroexpand form environment)))

(defun process-forms (forms environment)
  "Process forms and return a list of argument specifications.  A form may correspond to multiple arguments."
  (reduce #'append forms
          :key (lambda (f) (ensure-list (process-form f environment)))))

(defgeneric wrap-argument (argument pass parameters body)
  (:documentation "Return BODY wrapped in an environment generated for ARGUMENT in a given PASS.")
  (:method (argument pass parameters body)
    ;; default: just pass through body
    body))

(defun wrap-arguments (arguments pass parameters body)
  "Wrap BODY in arguments.  Convenienve function used to implement the expansion."
  (if arguments
      (wrap-argument (car arguments) pass parameters
                     (wrap-arguments (cdr arguments) pass parameters body))
      body))

(defun maybe-default-type (type parameters)
  "Return default type from parameters when TYPE is NIL."
  (aif type
       it
       (getf parameters :default-type)))

;;;; implementation of specific types

;;; fortran-argument

(defclass fortran-argument ()
  ((pointer
    :initform (gensym)
    :initarg :pointer
    :reader argument-pointer))
  (:documentation "Superclass of all arguments with pointers."))

(defun argument-pointers (arguments)
  "Return the list of pointers for all the arguments."
  (mapcar #'argument-pointer arguments))

(defclass fortran-argument/type (fortran-argument)
  ((type :initarg :type :initform nil)))

(defclass fortran-argument/size (fortran-argument)
  ((size :initarg :size :initform nil)))

;;; arguments with output

(defclass fortran-argument/output (fortran-argument)
  ((output
    :initarg :output
    :initform nil))
  (:documentation "Class for arguments that return an output.  When FORTRAN-ARGUMENT/OUTPUT-INITIALIZER-FORM returns non-NIL, a local binding of OUTPUT to this form will be wrapped around the relevant BODY."))

(defgeneric fortran-argument/output-initializer-form (argument parameters)
  (:documentation "When applicable, return a form that is used to initialize the OUTPUT variable.  When NIL is returned, no binding is established.")
  (:method ((argument fortran-argument/output) parameters)
    nil))

(defmacro &new (variable)
  "Placeholder macro for newly allocated output variables."
  (declare (ignore variable))
  (error "This macro is not meant to be expanded, it is only provided for editor hints."))

(defun fortran-argument/new-variable (form)
  "If FORM is (&NEW VARIABLE), return VARIABLE, otherwise NIL."
  (when (and (listp form)
             (= 2 (length form))
             (eq '&new (first form))
             (symbolp (second form)))
    (second form)))

(defun evaluated-output-form (form)
  (or (fortran-argument/new-variable form) form))

(defmethod wrap-argument ((argument fortran-argument/output) (pass (eql 'bindings))
                          parameters body)
  (let+ (((&slots-r/o output) argument)
         (variable (fortran-argument/new-variable output)))
    (if variable
        `(let ((,variable ,(fortran-argument/output-initializer-form
                            argument parameters)))
           ,body)
        body)))

;;; null pointer

(defmethod process-form ((form null) environment)
  (make-instance 'fortran-argument :pointer '(null-pointer)))

;;; characters

(defclass fortran-character (fortran-argument)
  ((character
    :initarg :character))
  (:documentation "Character passed to FORTRAN.  Input only, for specifying triangle orientation, etc."))

(defmethod wrap-argument ((argument fortran-character) (pass (eql 'main))
                          parameters body)
  (let+ (((&slots-r/o pointer character) argument))
    `(with-fortran-character (,pointer ,character)
       ,body)))

(defmacro &char (character)
  "Shorthand for character."
  (make-instance 'fortran-character :character character))

(defmethod process-form ((form character) env)
  (check-type form standard-char)
  (process-form `(&char ,form) env))

;;; atoms

(defclass fortran-atom (fortran-argument/output fortran-argument/type)
  ((value :initarg :value))
  (:documentation "Atoms passed to FORTRAN."))

(defmethod wrap-argument ((argument fortran-atom) (pass (eql 'main))
                          parameters body)
  (let+ (((&slots-r/o pointer value type output) argument))
    `(with-fortran-atom (,pointer ,value ,(maybe-default-type type parameters)
                                  ,output)
       ,body)))

(defmacro &atom (value &key type output)
  "Atoms passed to FORTRAN.  When not given, TYPE is inferred from the call's default.  VALUE is coerced to the desired type.  When OUTPUT is given, value is read after the call and placed there."
  (make-instance 'fortran-atom :value value :type type :output output))

(defmacro &integer (value &key output &environment env)
  "Shorthand for integer atom."
  (process-form `(&atom ,value :type +integer+ :output ,output) env))

(defmacro &integers (&rest values &environment env)
  "Shorthand for integer atoms which are not modified."
  (loop for value in values
        collect (process-form `(&integer ,value) env)))

(defmethod process-form ((form (eql 0)) env)
  (process-form '(&atom 0) env))

(defmethod process-form ((form (eql 1)) env)
  (process-form '(&atom 1) env))

;;; input arrays

(defclass fortran-input-array (fortran-argument)
  ((input
    :initarg :input)
   (input-type
    :initarg :input-type
    :initform nil)
   (input-transpose?
    :initarg :input-transpose?
    :initform nil)
   (input-force-copy?
    :initarg :input-force-copy?
    :initform nil))
  (:documentation "Arrays which are pinned."))

(defmacro &in-array (input &key type transpose? force-copy?)
  (make-instance 'fortran-input-array :input input
                                      :input-type type
                                      :input-transpose? transpose?
                                      :input-force-copy? force-copy?))

(defmethod wrap-argument ((argument fortran-input-array) (pass (eql 'main))
                          parameters body)
  (let+ (((&slots-r/o pointer input input-type input-transpose? input-force-copy?)
          argument))
    `(with-array-input ((,pointer)
                        ,input
                        ,(aif input-type
                              it
                              (getf parameters :default-type))
                        ,input-transpose?
                        ,input-force-copy?)
       ,body)))

;;; output arrays

(defclass fortran-output-array (fortran-argument/output)
  ((output
    :initarg :output)
   (output-dimensions
    :initarg :output-dimensions
    :initform nil)
   (output-type
    :initarg :output-type
    :initform nil)
   (output-transpose?
    :initarg :output-transpose?
    :initform nil))
  (:documentation "Output array."))

(defmacro &out-array (output &key dimensions type transpose?)
  (make-instance 'fortran-output-array :output output
                                       :output-dimensions dimensions
                                       :output-type type
                                       :output-transpose? transpose?))

(defmethod fortran-argument/output-initializer-form ((argument fortran-output-array)
                                                     parameters)
  (let+ (((&slots-r/o output-dimensions output-type) argument))
    `(make-array ,output-dimensions
                 :element-type (lisp-type
                                ,(maybe-default-type output-type
                                                     parameters)))))

(defmethod wrap-argument ((argument fortran-output-array) (pass (eql 'main))
                          parameters body)
  (let+ (((&slots-r/o pointer output output-type output-transpose?) argument))
    `(with-array-output ((,pointer)
                         ,(evaluated-output-form output)
                         ,(maybe-default-type output-type parameters)
                         ,output-transpose?)
       ,body)))

;;; input/output arrays

(defclass fortran-input-output-array (fortran-input-array fortran-output-array)
  ()
  (:documentation "Input/output array."))

(defmacro &in/out-array ((&key input
                               ((:type input-type))
                               ((:transpose? input-transpose?))
                               ((::force-copy? input-force-copy?) nil
                                input-force-copy?-specified?))
                         (&key (output input)
                               ((:dimensions output-dimensions))
                               ((:type output-type) input-type)
                               ((:transpose? output-transpose?))))
  (make-instance 'fortran-input-output-array
                 :input input
                 :input-type input-type
                 :input-transpose? input-transpose?
                 :input-force-copy? (if input-force-copy?-specified?
                                        input-force-copy?
                                        (not (eq input output)))
                 :output output
                 :output-dimensions output-dimensions
                 :output-type output-type
                 :output-transpose? output-transpose?))

(defmethod fortran-argument/output-initializer-form
    ((argument fortran-input-output-array) parameters)
  (let+ (((&slots-r/o input output-dimensions output-type) argument))
    `(make-array ,(or output-dimensions `(array-dimensions ,input))
                      :element-type (lisp-type
                                     ,(maybe-default-type output-type
                                                          parameters)))))

(defmethod wrap-argument ((argument fortran-input-output-array)
                          (pass (eql 'main)) parameters body)
  (let+ (((&slots-r/o pointer input input-type input-transpose? input-force-copy?
                      output output-type output-transpose?) argument))
    `(with-array-input-output ((,pointer)
                               ,input
                               ,(aif input-type
                                     it
                                     (getf parameters :default-type))
                               ,input-transpose?
                               ,input-force-copy?
                               ,(evaluated-output-form output)
                               ,(aif output-type
                                     it
                                     (getf parameters :default-type))
                               ,output-transpose?)
       ,body)))

;;; work arrays

(defclass fortran-work-area (fortran-argument/type fortran-argument/size)
  ()
  (:documentation "Work area."))

(defmacro &work (size &optional type)
  "Allocate a work area of SIZE.  When TYPE is not given, the call's default is used."
  (make-instance 'fortran-work-area :type type :size size))

(defmethod wrap-argument ((argument fortran-work-area) (pass (eql 'main))
                          parameters body)
  (let+ (((&slots-r/o pointer type size) argument))
    `(with-work-area (,pointer ,(maybe-default-type type parameters) ,size)
       ,body)))

;;; call info

(defclass lapack-info (fortran-argument)
  ((variable
    :initarg :variable
    :initform (gensym))
   (condition
    :initarg :condition)))

(defmacro &info (&optional (condition ''lapack-failure))
  "Argument for checking whether the call was executed without an error.  Automatically takes care of raising the appropriate condition if it wasn't.  CONDITION specifies the condition to raise in case of positive error codes."
  (make-instance 'lapack-info :condition condition))

(define-symbol-macro &info (&info))

(defun lapack-info-wrap-argument (argument body)
  (let+ (((&slots-r/o pointer variable condition) argument))
    `(let (,variable)
       (with-fortran-atom (,pointer 0 +integer+ ,variable)
         ,body)
       (cond
         ((minusp ,variable)
          (error 'lapack-invalid-argument :position (- ,variable)))
         ((plusp ,variable)
          (error ',condition :info ,variable))))))

(defmethod wrap-argument ((argument lapack-info) (pass (eql 'call)) parameters body)
  (lapack-info-wrap-argument argument body))

(defmethod wrap-argument ((argument lapack-info) (pass (eql 'query)) parameters body)
  (lapack-info-wrap-argument argument body))

;;; work area query
;;;
;;; &work-query expands to TWO structures which share a SIZE argument, they cooperate for the query.

(defclass lapack-work-query-area (fortran-argument/size fortran-argument/type)
  ())

(defclass lapack-work-query-size (fortran-argument/size)
  ())

(defmacro &work-query (&optional type)
  "Work area query, takes the place of TWO fortran arguments."
  (let ((size (gensym)))
    (list (make-instance 'lapack-work-query-area :size size :type type)
          (make-instance 'lapack-work-query-size :size size))))

(defmethod wrap-argument ((argument lapack-work-query-area)
                          (pass (eql 'bindings)) parameters body)
  (assert (getf parameters :query?) () "Call macro does not support queries.")
  `(let (,(slot-value argument 'size))
     ,body))

(defmethod wrap-argument ((argument lapack-work-query-area)
                          (pass (eql 'query)) parameters body)
  (let+ (((&slots-r/o pointer size type) argument))
    `(progn
       (with-fortran-atom (,pointer 0 ,(maybe-default-type type parameters) ,size)
         ,body)
       (setf ,size (as-integer ,size)))))

(defmethod wrap-argument ((argument lapack-work-query-size)
                          (pass (eql 'query)) parameters body)
  (let+ (((&slots-r/o pointer) argument))
    `(with-fortran-atom (,pointer -1 +integer+ nil)
       ,body)))

(defmethod wrap-argument ((argument lapack-work-query-area)
                          (pass (eql 'call)) parameters body)
  (let+ (((&slots-r/o pointer size type) argument))
    `(with-work-area (,pointer ,(maybe-default-type type parameters) ,size)
       ,body)))

(defmethod wrap-argument ((argument lapack-work-query-size)
                          (pass (eql 'call)) parameters body)
  (let+ (((&slots-r/o pointer size) argument))
    `(with-fortran-atom (,pointer ,size +integer+ nil)
       ,body)))

;;; various call interfaces

(defun blas-lapack-function-name (type name)
  "Return the BLAS/LAPACK foreign function name.  TYPE is the internal type, NAME is one of the following: NAME, (NAME), which are used for both complex and real names, or (REAL-NAME COMPLEX-NAME)."
  (let+ (((real-name &optional (complex-name name)) (ensure-list name))
         (letter (switch (type)
                   (+single+ "S")
                   (+double+ "D")
                   (+complex-single+ "C")
                   (+complex-double+ "Z")))
         (name (if (complex? type)
                   complex-name
                   real-name)))
    (format nil "~(~A~A_~)" letter name)))

(defun arguments-for-cffi (arguments)
  "Return a list that can be use in a CFFI call."
  (loop for arg in arguments appending `(:pointer ,(argument-pointer arg))))

(defun blas-lapack-call-form (type-var name arguments)
  "Return a form BLAS/LAPACK calls, conditioning on TYPE-VAR.  See BLAS-LAPACK-FUNCTION-NAME for the interpretation of FIXME"
  (let ((arguments (arguments-for-cffi arguments)))
    `(ecase ,type-var
       ,@(loop for type in +float-types+
               collect
               `(,type
                 (cffi:foreign-funcall
                  ,(blas-lapack-function-name type name)
                  ,@arguments
                  :void))))))

;;;; Main interface
;;;
;;; Common conventions:
;;;
;;;  1. NAME is either a string or a list of two strings (real/complex)
;;;
;;;  2. VALUE is the form returned after the call

(defmacro blas-call ((name type value) &body forms &environment env)
  "BLAS call."
  (let* ((type-var (gensym "TYPE"))
         (arguments (process-forms forms env))
         (parameters `(:default-type ,type-var)))
    `(let ((,type-var ,type))
       ,(wrap-arguments
         arguments 'bindings parameters
         `(progn
            ,(wrap-arguments arguments 'main parameters
                             (blas-lapack-call-form type-var name arguments))
            ,value)))))

(defun assert-single-lapack-info (arguments)
  "Assert that there is at most one LAPACK-INFO in ARGUMENTS."
  (assert (<= (loop for argument in arguments
                    count (typep argument 'lapack-info))
              1)))

(defmacro lapack-call ((name type value) &body forms &environment env)
  "LAPACK call, takes an &info argument."
  (let* ((type-var (gensym "TYPE"))
         (arguments (process-forms forms env))
         (parameters `(:default-type ,type-var)))
    (assert-single-lapack-info arguments)
    `(let ((,type-var ,type))
       ,(wrap-arguments
         arguments 'bindings parameters
         `(progn
            ,(wrap-arguments
              arguments 'main parameters
              (wrap-arguments arguments 'call parameters
                              (blas-lapack-call-form type-var name
                                                     arguments)))
            ,value)))))

(defmacro lapack-call-w/query ((name type value) &body forms &environment env)
  "LAPACK call which also takes &work-query arguments (in place of two FORTRAN arguments)."
  (let* ((type-var (gensym "TYPE"))
         (arguments (process-forms forms env))
         (parameters `(:default-type ,type-var :query? t))
         (call-form (blas-lapack-call-form type-var name arguments)))
    (assert-single-lapack-info arguments)
    `(let ((,type-var ,type))
       ,(wrap-arguments
         arguments 'bindings parameters
         `(progn
            ,(wrap-arguments
              arguments 'main parameters
              `(progn
                 ,(wrap-arguments arguments 'query parameters call-form)
                 ,(wrap-arguments arguments 'call parameters call-form)))
            ,value)))))

;;;; floating point traps
;;;
;;; Apparently, the only trap that we need to mask is division by zero, and that only for a few operations.  Non-numerical floating points values are used internally (eg in SVD calculations), but only reals are returned.

#-(or sbcl cmu)
(defmacro with-fp-traps-masked (&body body)
  (warn "No with-lapack-traps-masked macro provided for your implementation -- some operations may signal an error.")
  `(progn
     ,@body))

#+sbcl
(defmacro with-fp-traps-masked (&body body)
  `(sb-int:with-float-traps-masked (:divide-by-zero :invalid)
     ,@body))

#+cmu
(defmacro with-fp-traps-masked (&body body)
  `(extensions:with-float-traps-masked (:divide-by-zero :invalid)
     ,@body))

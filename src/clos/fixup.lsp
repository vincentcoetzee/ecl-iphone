;;;;  Copyright (c) 1992, Giuseppe Attardi.
;;;;
;;;;    This program is free software; you can redistribute it and/or
;;;;    modify it under the terms of the GNU Library General Public
;;;;    License as published by the Free Software Foundation; either
;;;;    version 2 of the License, or (at your option) any later version.
;;;;
;;;;    See file '../Copyright' for full details.

(in-package "CLOS")

;;; ----------------------------------------------------------------------
;;; Fixup

(dolist (method-info *early-methods*)
  (let* ((method-name (car method-info))
	 (gfun (fdefinition method-name))
	 (standard-method-class (find-class 'standard-method)))
    (when (eq 'T (class-id (si:instance-class gfun)))
      ;; complete the generic function object
      (si:instance-class-set gfun (find-class 'STANDARD-GENERIC-FUNCTION))
      (si::instance-sig-set gfun)
      (setf (generic-function-method-class gfun) standard-method-class)
      )
    (dolist (method (cdr method-info))
      ;; complete the method object
      (si::instance-class-set method (find-class 'standard-method))
      (si::instance-sig-set gfun)
      )
    (makunbound '*EARLY-METHODS*)))


;;; ----------------------------------------------------------------------
;;;                                                              redefined

(defun method-p (method) (typep method 'METHOD))

(defun make-method (qualifiers specializers arglist
			       function plist options gfun method-class)
  (declare (ignore options))
  (make-instance method-class
		 :generic-function nil
		 :qualifiers qualifiers
		 :lambda-list arglist
		 :specializers specializers
		 :function function
		 :plist plist
		 :allow-other-keys t))

(defun all-keywords (l)
  (declare (si::cl-local))
  (let ((all-keys '()))
    (do ((l (rest l) (cddddr l)))
	((null l)
	 all-keys)
      (push (first l) all-keys))))

(defun congruent-lambda-p (l1 l2)
  (multiple-value-bind (r1 opts1 rest1 key-flag1 keywords1 a-o-k1)
      (si::process-lambda-list l1 'FUNCTION)
    (multiple-value-bind (r2 opts2 rest2 key-flag2 keywords2 a-o-k2)
	(si::process-lambda-list l2 'FUNCTION)
	(and (= (length r2) (length r1))
	     (= (length opts1) (length opts2))
	     (eq (and (null rest1) (null key-flag1))
		 (and (null rest2) (null key-flag2)))
	     ;; All keywords mentioned in the genericf function
	     ;; must be accepted by the method.
	     (or (null key-flag1)
		 (null key-flag2)
		 a-o-k2
		 (null (set-difference (all-keywords keywords1)
					   (all-keywords keywords2))))
	     t))))

(defun add-method (gf method)
  (declare (notinline method-qualifiers)) ; during boot it's a structure accessor
  ;;
  ;; 1) The method must not be already installed in another generic function.
  ;;
  (let ((other-gf (method-generic-function method)))
    (unless (or (null other-gf) (eq other-gf gf))
      (error "The method ~A belongs to the generic function ~A ~
and cannot be added to ~A." method other-gf gf)))
  ;;
  ;; 2) The method and the generic function should have congruent lambda
  ;;    lists. That is, it should accept the same number of required and
  ;;    optional arguments, and only accept keyword arguments when the generic
  ;;    function does.
  ;;
  (let ((new-lambda-list (method-lambda-list method)))
    (if (slot-boundp gf 'lambda-list)
	(let ((old-lambda-list (generic-function-lambda-list gf)))
	  (unless (congruent-lambda-p old-lambda-list new-lambda-list)
	    (error "Cannot add the method ~A to the generic function ~A because ~
their lambda lists ~A and ~A are not congruent."
		   method gf old-lambda-list new-lambda-list)))
	(reinitialize-instance gf :lambda-list new-lambda-list)))
  ;;
  ;; 3) Finally, it is inserted in the list of methods, and the method is
  ;;    marked as belonging to a generic function.
  ;;
  (when (generic-function-methods gf)
    (let* ((method-qualifiers (method-qualifiers method)) 
	   (specializers (method-specializers method))
	   found)
      (when (setq found (find-method gf method-qualifiers specializers nil))
	(remove-method gf found))))
  ;;
  ;; We install the method by:
  ;;  i) Adding it to the list of methods
  (push method (generic-function-methods gf))
  (setf (method-generic-function method) gf)
  ;;  ii) Updating the specializers list of the generic function. Notice that
  ;;  we should call add-direct-method for each specializer but specializer
  ;;  objects are not yet implemented
  #+(or)
  (dolist (spec (method-specializers method))
    (add-direct-method spec method))
  ;;  iii) Computing a new discriminating function... Well, since the core
  ;;  ECL does not need the discriminating function because we always use
  ;;  the same one, we just update the spec-how list of the generic function.
  (compute-g-f-spec-list gf)
  gf)

(setf (method-function
       (eval '(defmethod false-add-method ((gf standard-generic-function)
					   (method standard-method)))))
      #'add-method)
(setf (fdefinition 'add-method) #'false-add-method)
(setf (generic-function-name #'add-method) 'add-method)

(defun remove-method (gf method)
  (setf (generic-function-methods gf)
	(delete method (generic-function-methods gf))
	(method-generic-function method) nil)
  (clrhash (generic-function-method-hash gf))
  gf)

;;; ----------------------------------------------------------------------
;;; Error messages

(defmethod no-applicable-method (gf &rest args)
    (declare (ignore args))
  (error "No applicable method for ~S" 
	 (generic-function-name gf)))

(defmethod no-next-method (gf method &rest args)
  (declare (ignore gf args))
  (error "In method ~A~%No next method given arguments ~A" method args))

(defun no-primary-method (gf &rest args)
  (error "Generic function: ~A. No primary method given arguments: ~S"
	 (generic-function-name gf) args))

;;; Now we protect classes from redefinition:
(eval-when (compile load)
(defun setf-find-class (new-value name &optional errorp env)
  (let ((old-class (find-class name nil)))
    (cond
      ((typep old-class 'built-in-class)
       (error "The class associated to the CL specifier ~S cannot be changed."
	      name))
      ((member name '(CLASS BUILT-IN-CLASS) :test #'eq)
       (error "The kernel CLOS class ~S cannot be changed." name))
      ((classp new-value)
       (setf (gethash name si:*class-name-hash-table*) new-value))
      ((null new-value) (remhash name si:*class-name-hash-table*))
      (t (error "~A is not a class." new-value))))
  new-value)
)

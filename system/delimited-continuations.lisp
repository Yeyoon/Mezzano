;;;; Copyright (c) 2018 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(in-package :mezzano.delimited-continuations)

(deftype delimited-continuation ()
  `(satisfies delimited-continuation-p))

(declaim (inline delimited-continuation-p))
(defun delimited-continuation-p (object)
  (sys.int::%object-of-type-p object sys.int::+object-tag-delimited-continuation+))

(define-condition consumed-continuation-resumed (control-error)
  ((continuation :initarg :continuation
                 :reader consumed-continuation-resumed-continuation)
   (arguments :initarg :arguments
              :initform '()
              :reader consumed-continuation-resumed-arguments))
  (:report (lambda (condition stream)
             (format stream "Attempted to resume consumed continuation ~S with arguments ~:S."
                     (consumed-continuation-resumed-continuation condition)
                     (consumed-continuation-resumed-arguments condition)))))

(define-condition barrier-present (control-error)
  ((tag :initarg :tag
        :reader barrier-present-tag)
   (barrier :initarg :barrier
        :reader barrier-present-barrier))
  (:report (lambda (condition stream)
             (format stream "Cannot abort to prompt ~S, blocked by barrier ~S."
                     (barrier-present-tag condition)
                     (barrier-present-barrier condition)))))

(define-condition unknown-prompt-tag (control-error)
  ((tag :initarg :tag
        :reader unknown-prompt-tag-tag))
  (:report (lambda (condition stream)
             (format stream "Unknown prompt tag ~S."
                     (unknown-prompt-tag-tag condition)))))

(defstruct (prompt-tag
             (:constructor make-prompt-tag (&optional (stem "prompt"))))
  (stem nil :read-only t))

(defparameter *default-prompt-tag* (make-prompt-tag "default-prompt"))

;; This internal tag is used by continuations that have been resumed normally,
;; not via CALL-WITH-PROMPT, and are not elegible for ABORT-TO-PROMPT.
(sys.int::defglobal *ignore-prompt-tag* (make-prompt-tag "ignore-prompt"))

;; This is bound whenever a continuation barrier must be established.
;; It's not a real variable, just a marker in the special stack.
(defparameter *continuation-barrier* nil)

(defun resumable-p (delimited-continuation)
  "Returns true if DELIMITED-CONTINUATION can be resumed."
  (check-type delimited-continuation delimited-continuation)
  (eql (sys.int::%object-ref-t delimited-continuation
                               sys.int::+delimited-continuation-state+)
       :resumable))

(defun call-with-prompt (prompt-tag thunk handler &key stack-size)
  (check-type thunk function)
  (check-type handler function)
  (check-type prompt-tag prompt-tag)
  (cond ((delimited-continuation-p thunk)
         ;; Resuming an existing continuation, reuse the stack.
         ;; Attempt to take ownership of this continuation.
         (when (not (sys.int::%cas-object thunk sys.int::+delimited-continuation-state+
                                          :resumable :consumed))
           (error 'consumed-continuation-resumed
                  :continuation thunk
                  :arguments '()))
         (let ((prompt (sys.int::%object-ref-t thunk sys.int::+delimited-continuation-prompt+)))
           ;; Update the continuation tag.
           (setf (sys.int::%object-ref-t prompt 1) prompt-tag)
           ;; And the handler.
           (setf (sys.int::%object-ref-t prompt 2) handler))
         ;; Then resume it, going through our helper because we consumed it.
         (%reinvoke-delimited-continuation thunk))
        (t
         ;; Starting a new stack slice.
         (%call-with-prompt prompt-tag
                            thunk
                            handler
                            (mezzano.supervisor::%allocate-stack
                             (or stack-size
                                 mezzano.supervisor::*default-stack-size*))))))

(defun find-prompt (prompt-tag &optional (errorp t))
  "Walk the special stack looking for the nearest matching prompt tag.
Returns the matching special stack entry if one is found, NIL otherwise.
The second returned value is true if a continuation barrier is present."
  (check-type prompt-tag prompt-tag)
  (loop
     with barrier = nil
     for ssp = (sys.int::%%special-stack-pointer) then (svref ssp 0)
     when (eql (svref ssp 1) prompt-tag)
     do (return (values ssp barrier))
     when (eql (svref ssp 1) '*continuation-barrier*)
     do (setf barrier (svref ssp 2))
     finally
       (if errorp
           (error 'unknown-prompt-tag :tag prompt-tag)
           (return (values nil nil)))))

(defmacro abort-to-prompt (prompt-tag &optional (result-form '(values)))
  "Abort to the prompt specified by PROMPT-TAG, passing the values of RESULT-FORM to the handler."
  `(abort-to-prompt-1 ,prompt-tag
                      (multiple-value-list ,result-form)))

(defun abort-to-prompt-1 (prompt-tag values)
  (assert (not (eql prompt-tag *ignore-prompt-tag*)))
  (multiple-value-bind (prompt barrier)
      (find-prompt prompt-tag)
    (cond (barrier
           (error 'barrier-present
                  :tag prompt-tag
                  :barrier barrier))
          (t
           (%abort-to-prompt prompt values)))))

(defun call-with-continuation-barrier (thunk &optional reason)
  (let ((*continuation-barrier* (or reason t)))
    (funcall thunk)))

(defmacro with-continuation-barrier ((&optional reason) &body body)
  `(call-with-continuation-barrier (lambda () ,@body) ,reason))

(defun suspendable-continuation-p (prompt-tag)
  "Returns true if there is a matching active prompt-tag with no intervening barriers."
  (multiple-value-bind (prompt barrier)
      (find-prompt prompt-tag nil)
    (if prompt
        (not barrier)
        nil)))

;; Helper function for %RESUME-DELIMITED-CONTINUATION.
(defun raise-consumed-continuation-resumed (&rest args sys.int::&closure continuation)
  (error 'consumed-continuation-resumed
         :continuation continuation
         :arguments args))

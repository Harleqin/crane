;;;; Normally I would use SxQL for table creation and alteration, but the
;;;; sources are too obscure for me to grok, and I don't want to have to
;;;; contribue a pull request just to get basic functionality working. So, for
;;;; now, CREATE TABLE and MIGRATE TABLE statements will be produced as raw
;;;; strings. How horrifying.

(defpackage :crane.sql
  (:use :cl :anaphora :crane.utils :cl-annot.doc :iter))
(in-package :crane.sql)
(annot:enable-annot-syntax)

@export
(defun sqlize (obj)
  (typecase obj
    (symbol
     (sqlize (symbol-name obj)))
    (string
     (map 'string #'(lambda (char) (if (eql char #\-) #\_ char))
          obj))))

@doc "Give constraints Crane-specific names"
(defun constraint-name (column-name type)
  (concatenate 'string "crane_" column-name "_" type))

@doc "Toggle NULL constraint."
(defun set-null (column-name value)
  (unless value
    (concatenate 'string "CHECK (" column-name " IS NOT NULL)")))

@doc "Toggle UNIQUE constraint."
(defun set-unique (column-name value)
  (when value
    (concatenate 'string "UNIQUE (" column-name ")")))

@doc "Toggle PRIMARY KEY constraint."
(defun set-primary (column-name value)
  (when value
    (concatenate 'string "PRIMARY KEY (" column-name ")")))

@doc "Toggle INDEX pseudo-constraint."
(defun set-index (table-name column-name value)
  (if value
    (list :external
          (format nil "CREATE INDEX ~A ON ~A (~A)"
                  (constraint-name column-name "INDEX")
                  table-name
                  column-name))
    (list :external
          (format nil "DROP INDEX ~A ON ~A"
                  (constraint-name column-name "INDEX")
                  table-name))))

(defparameter +referential-actions+
  (list :cascade "CASCADE"
        :restrict "RESTRICT"
        :no-action "NO ACTION"
        :set-null "SET NULL"
        :set-default "SET DEFAULT"))

(defun map-ref-action (action)
  (aif (getf +referential-actions+ action)
       it
       (error "No such referential action: ~A" action)))

(defun foreign (local foreign &key (on-delete :no-action) (on-update :no-action))
  (format nil "FOREIGN KEY ~A REFERENCES (~A) ON DELETE ~a ON UPDATE"
          local
          foreign
          (map-ref-action on-delete)
          (map-ref-action on-update)))

@doc "Create a constraint from its type and values, if it can be
created (eg :nullp t doesn't create a constraint, but :nullp nil creates a NOT
NULL constraint)."
@export
(defun make-constraint (table-name column-name type value)
  (if (eql type :indexp)
      ;; :indexp is treated especially, because it generates an external command
      ;; which already includes the constraint name
      (when value (set-index table-name column-name value))
      (aif (ecase type
             (:nullp
              (set-null column-name value))
             (:uniquep
              (set-unique column-name value))
             (:primaryp
              (set-primary column-name value)))
           (concatenate 'string
                        "CONSTRAINT "
                        (constraint-name column-name (sqlize type))
                        " "
                        it))))


(defun create-column-constraints (table-name column)
  (let ((column-name (getf column :name)))
    (remove-if #'null
               (iter (for key in '(:nullp :uniquep :primaryp :indexp))
                 (collecting (make-constraint table-name
                                              (sqlize column-name)
                                              key
                                              (getf column key)))))))

@export
(defun define-column (table-name column)
  (let* ((column-definition
           (concatenate 'string
                        (sqlize (getf column :name))
                        " "
                        (sqlize-type (getf column :type))))
         (constraints
           (create-column-constraints table-name column))
         (internal-constraints
           (remove-if-not #'stringp constraints))
         (external-constraints
           (mapcar #'cadr
                   (remove-if-not #'listp constraints))))
    (list :definition column-definition
          :internal internal-constraints
          :external external-constraints)))

@export
(defun create-and-sort-constraints (table-name digest)
  (let ((definitions
          (mapcar #'(lambda (col)
                      (define-column table-name col))
                  (getf digest :columns))))
    (list :definition (mapcar #'(lambda (def) (getf def :definition)) definitions)
          :internal (reduce #'append
                            (mapcar #'(lambda (def) (getf def :internal)) definitions))
          :external (reduce #'append
                            (mapcar #'(lambda (def) (getf def :external)) definitions)))))

;;;; Constraint processing is stupid, I wish I was coding something more fun :c

;;;; Alter Table

@export
(defun add-constraint (table-name column-name body)
  (format nil "ALTER TABLE ~A ADD ~A;"
          table-name
          body))

@export
(defun drop-constraint (table-name column-name type)
  (format nil "ALTER TABLE ~A DROP CONSTRAINT ~A;"
          table-name
          (constraint-name column-name type)))

@export
(defun alter-constraint (table-name column-name type value)
  (if (member type (list :primaryp :uniquep :indexp :foreign :check))
      (if value
          ;; The constraint wasn't there, add it
          (aif (make-constraint table-name column-name type t)
               (add-constraint table-name
                               column-name
                               it))
          ;; The constraint has been dropped
          (drop-constraint table-name
                           column-name
                           (sqlize type)))
      ;; NULL constraint
      (if value
          ;; Set null
          (aif (make-constraint table-name column-name :nullp t)
               (add-constraint table-name
                               column-name
                               it))
          ;; Remove null constraint
          (drop-constraint table-name
                           column-name
                           (sqlize type)))))

@export
(defun drop-column (table-name column-name)
  (format nil "ALTER TABLE ~A DROP COLUMN ~A" table-name column-name))

;;;; Utility functions

@export
(defun sqlize-type (type)
  (format nil "~A" type))

@doc "Prepare a query for execution"
@export
(defun prepare (query &optional (database-name crane:*default-db*))
  (when (debugp)
    (print query))
  (dbi:prepare (crane:get-connection database-name) query))

@doc "Execute a query."
@export
(defun execute (query &rest args)
  (apply #'dbi:execute (cons query args)))

;;; spacelift-stack.el --- Stack structs and API for Spacelift -*- lexical-binding: t; -*-

;; Author: drlkf
;; Keywords: tools, processes
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Runtime representation of Spacelift stacks and the API functions used
;; to fetch them through `spacectl'.  Display and interactive logic lives
;; in `spacelift-ui.el'.

;;; Code:

(require 'cl-lib)
(require 'spacelift-core)

(cl-defstruct (spacelift-commit (:constructor spacelift-commit-create))
  "A commit attached to a stack or run."
  hash author login message timestamp url)

(cl-defstruct (spacelift-stack (:constructor spacelift-stack-create))
  "Runtime representation of a Spacelift stack.
Slot RAW holds the original parsed alist so that the detail view can
display fields not promoted to dedicated slots."
  id name description state branch namespace repository provider
  project-root labels autodeploy locked worker-pool-name space-name
  vendor tracked-commit created-at state-set-at raw)

(defun spacelift-stack--parse-commit (object)
  "Build a `spacelift-commit' from OBJECT alist, or nil when OBJECT is nil."
  (when object
    (spacelift-commit-create
     :hash (spacelift--alist-get 'hash object)
     :author (spacelift--alist-get 'authorName object)
     :login (spacelift--alist-get 'authorLogin object)
     :message (spacelift--alist-get 'message object)
     :timestamp (spacelift--alist-get 'timestamp object)
     :url (spacelift--alist-get 'url object))))

(defun spacelift-stack--parse (object)
  "Build a `spacelift-stack' from a parsed JSON OBJECT alist."
  (let ((space (spacelift--alist-get 'spaceDetails object))
        (worker (spacelift--alist-get 'workerPool object))
        (vendor (or (spacelift--alist-get 'vendorConfig object)
                    (spacelift--alist-get 'VendorConfig object))))
    (spacelift-stack-create
     :id (spacelift--alist-get 'id object)
     :name (spacelift--alist-get 'name object)
     :description (spacelift--alist-get 'description object)
     :state (spacelift--alist-get 'state object)
     :branch (spacelift--alist-get 'branch object)
     :namespace (spacelift--alist-get 'namespace object)
     :repository (spacelift--alist-get 'repository object)
     :provider (spacelift--alist-get 'provider object)
     :project-root (spacelift--alist-get 'projectRoot object)
     :labels (spacelift--alist-get 'labels object)
     :autodeploy (spacelift--alist-get 'autodeploy object)
     :locked (and (spacelift--alist-get 'Blocker object) t)
     :worker-pool-name (spacelift--alist-get 'name worker)
     :space-name (spacelift--alist-get 'name space)
     :vendor (or (spacelift--alist-get 'vendor vendor)
                 (spacelift--alist-get 'Vendor vendor))
     :tracked-commit (spacelift-stack--parse-commit
                      (spacelift--alist-get 'trackedCommit object))
     :created-at (spacelift--alist-get 'createdAt object)
     :state-set-at (spacelift--alist-get 'stateSetAt object)
     :raw object)))

;;; API

(defun spacelift-stack-list (&optional search limit)
  "Return a list of `spacelift-stack' the user has access to.
SEARCH, when non-nil, is a full-text search string.  LIMIT, when
non-nil, caps the number of returned stacks."
  (let ((args '("stack" "list")))
    (when search
      (setq args (append args (list "--search" search))))
    (when limit
      (setq args (append args (list "--limit" (number-to-string limit)))))
    (mapcar #'spacelift-stack--parse (apply #'spacelift--run-json args)))) 

(defun spacelift-stack-show (id)
  "Return the detailed `spacelift-stack' identified by ID."
  (spacelift-stack--parse
   (spacelift--run-json "stack" "show" "--id" id)))

(provide 'spacelift-stack)

;;; spacelift-stack.el ends here

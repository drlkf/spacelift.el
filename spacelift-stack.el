;;; spacelift-stack.el --- Stack structs and API for Spacelift -*- lexical-binding: t; -*-

;; Copyright (C) 2026 drlkf

;; Author: drlkf <drlkf@drlkf.net>
;; Assisted-by: Claude:claude-opus-4-8
;; Keywords: tools, processes
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/drlkf/spacelift.el

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Runtime representation of Spacelift stacks and the API functions used
;; to fetch them through `spacectl'.  Display and interactive logic lives
;; in `spacelift-ui.el'.

;;; Code:

(require 'cl-lib)
(require 'seq)
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
  vendor tracked-commit created-at state-set-at blocker-id blocker-state
  blocker-commit blocker-branch raw)

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
                    (spacelift--alist-get 'VendorConfig object)))
        (blocker (spacelift--alist-get 'Blocker object)))
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
     :blocker-id (spacelift--alist-get 'id blocker)
     :raw object)))

(defun spacelift-stack-display-state (stack)
  "Return the state to display for STACK.
When STACK is blocked by a run (its `blocker-state' is known), return
that run's state, the current/blocking run; otherwise return the stack's
own settled state."
  (or (spacelift-stack-blocker-state stack)
      (spacelift-stack-state stack)))

(defun spacelift-stack-display-commit (stack)
  "Return the commit to display for STACK.
When STACK is blocked by a run, return that run's commit, the
current/blocking run; otherwise return the stack's tracked commit."
  (or (spacelift-stack-blocker-commit stack)
      (spacelift-stack-tracked-commit stack)))

(defun spacelift-stack-display-branch (stack)
  "Return the branch to display for STACK.
When STACK is blocked by a run, return that run's branch, the
current/blocking run; otherwise return the stack's tracked branch."
  (or (spacelift-stack-blocker-branch stack)
      (spacelift-stack-branch stack)))

(defun spacelift-stack-successful-p (stack)
  "Return non-nil when STACK's displayed state is the successful FINISHED state."
  (equal (spacelift-stack-display-state stack) "FINISHED"))

;;; API

;; The `spacectl' stack listing reports a blocking run only as its id
;; (`Blocker'), never its details, so the list keeps showing the stack's
;; settled state and tracked commit while a run is actually queued or in
;; progress against a different commit.  The blocker run's state, commit
;; and branch are fetched separately through GraphQL and promoted into the
;; stack so the display can show the current/blocking run.

(defconst spacelift-stack--blocker-fields
  "state branch commit { hash authorName authorLogin message timestamp url }"
  "GraphQL selection for the fields promoted from a stack's blocking run.")

(defun spacelift-stack--set-blocker (stack blocker)
  "Populate STACK's blocker slots from the BLOCKER run alist, in place."
  (setf (spacelift-stack-blocker-state stack)
        (spacelift--alist-get 'state blocker))
  (setf (spacelift-stack-blocker-branch stack)
        (spacelift--alist-get 'branch blocker))
  (setf (spacelift-stack-blocker-commit stack)
        (spacelift-stack--parse-commit
         (spacelift--alist-get 'commit blocker))))

(defun spacelift-stack--blocker-map ()
  "Return a hash of stack id to blocker run alist for all blocked stacks.
Fetched in a single GraphQL call; stacks without a blocking run are
omitted."
  (let ((data (spacelift--run-graphql
               (format "{ stacks { id blocker { %s } } }"
                       spacelift-stack--blocker-fields)))
        (map (make-hash-table :test 'equal)))
    (dolist (stack (spacelift--alist-get 'stacks data))
      (let ((id (spacelift--alist-get 'id stack))
            (blocker (spacelift--alist-get 'blocker stack)))
        (when (and id blocker)
          (puthash id blocker map))))
    map))

(defun spacelift-stack--enrich-blockers (stacks)
  "Populate the blocker slots of each blocked stack in STACKS, in place.
When no stack in STACKS is blocked, no GraphQL call is made.  Return
STACKS."
  (when (seq-some #'spacelift-stack-blocker-id stacks)
    (let ((map (spacelift-stack--blocker-map)))
      (dolist (stack stacks)
        (when (spacelift-stack-blocker-id stack)
          (spacelift-stack--set-blocker
           stack (gethash (spacelift-stack-id stack) map))))))
  stacks)

(defun spacelift-stack-list (&optional search limit)
  "Return a list of `spacelift-stack' the user has access to.
SEARCH, when non-nil, is a full-text search string.  LIMIT, when
non-nil, caps the number of returned stacks.  Stacks with a blocking run
are enriched with that run's state in `blocker-state'.  The returned
stacks are sorted case-insensitively by name."
  (let ((args '("stack" "list")))
    (when search
      (setq args (append args (list "--search" search))))
    (when limit
      (setq args (append args (list "--limit" (number-to-string limit)))))
    (seq-sort-by (lambda (stack) (downcase (or (spacelift-stack-name stack) "")))
                 #'string-lessp
                 (spacelift-stack--enrich-blockers
                  (mapcar #'spacelift-stack--parse
                          (apply #'spacelift--run-json args))))))

(defun spacelift-stack-show (id)
  "Return the detailed `spacelift-stack' identified by ID.
When the stack is blocked by a run, that run's state, commit and branch
are fetched and promoted into the stack."
  (let ((stack (spacelift-stack--parse
                (spacelift--run-json "stack" "show" "--id" id))))
    (when (spacelift-stack-blocker-id stack)
      (let* ((data (spacelift--run-graphql
                    (format
                     "query($id: ID!) { stack(id: $id) { blocker { %s } } }"
                     spacelift-stack--blocker-fields)
                    `((id . ,id))))
             (blocker (spacelift--alist-get
                       'blocker (spacelift--alist-get 'stack data))))
        (spacelift-stack--set-blocker stack blocker)))
    stack))

(provide 'spacelift-stack)

;;; spacelift-stack.el ends here

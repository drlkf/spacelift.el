;;; spacelift-run.el --- Run structs and API for Spacelift -*- lexical-binding: t; -*-

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

;; Runtime representation of Spacelift runs and the API functions used to
;; fetch them through `spacectl'.  Runs are children of a stack; the
;; Spacelift run list JSON does not carry the parent stack id, so it is
;; threaded in explicitly when parsing.  Display and interactive logic
;; lives in `spacelift-ui.el'.

;;; Code:

(require 'cl-lib)
(require 'spacelift-core)
(require 'spacelift-stack)

(cl-defstruct (spacelift-run (:constructor spacelift-run-create))
  "Runtime representation of a Spacelift run.
STACK-ID is the parent stack slug, threaded in at parse time so the
console URL can be built.  Slot RAW holds the original parsed alist."
  id stack-id state title branch created-at triggered-by needs-approval
  drift-detection most-recent commit delta raw)

(defun spacelift-run--parse-delta (object)
  "Return a human-readable resource delta string from OBJECT, or nil."
  (when object
    (let ((add (spacelift--alist-get 'addCount object 0))
          (change (spacelift--alist-get 'changeCount object 0))
          (delete (spacelift--alist-get 'deleteCount object 0)))
      (format "+%d ~%d -%d" add change delete))))

(defun spacelift-run--parse (object stack-id)
  "Build a `spacelift-run' from a parsed JSON OBJECT under STACK-ID."
  (spacelift-run-create
   :id (spacelift--alist-get 'id object)
   :stack-id stack-id
   :state (spacelift--alist-get 'state object)
   :title (spacelift--alist-get 'title object)
   :branch (spacelift--alist-get 'branch object)
   :created-at (spacelift--alist-get 'createdAt object)
   :triggered-by (spacelift--alist-get 'triggeredBy object)
   :needs-approval (spacelift--alist-get 'needsApproval object)
   :drift-detection (spacelift--alist-get 'driftDetection object)
   :most-recent (spacelift--alist-get 'isMostRecent object)
   :commit (spacelift-stack--parse-commit
            (spacelift--alist-get 'commit object))
   :delta (spacelift-run--parse-delta (spacelift--alist-get 'delta object))
   :raw object))

(defun spacelift-run-browse-url (run)
  "Return the Spacelift console URL for RUN."
  (spacelift-run-url (spacelift-run-stack-id run) (spacelift-run-id run)))

;;; API

(defun spacelift-stack-run-list (stack-id &optional max-results preview)
  "Return a list of `spacelift-run' for the stack identified by STACK-ID.
MAX-RESULTS, when non-nil, caps the number of runs returned.  When
PREVIEW is non-nil, preview (proposed) runs are returned."
  (let ((args (list "stack" "run" "list" "--id" stack-id)))
    (when max-results
      (setq args (append args (list "--max-results"
                                    (number-to-string max-results)))))
    (when preview
      (setq args (append args (list "--preview-runs"))))
    (mapcar (lambda (object) (spacelift-run--parse object stack-id))
            (apply #'spacelift--run-json args))))

(defun spacelift-run-confirm (run &optional run-metadata)
  "Confirm the unconfirmed tracked RUN via `spacectl stack confirm'.
RUN-METADATA, when non-nil, is passed as `--run-metadata'.  Return
`spacectl''s raw output.  This is a write operation."
  (let ((args (list "stack" "confirm"
                    "--id" (spacelift-run-stack-id run)
                    "--run" (spacelift-run-id run))))
    (when run-metadata
      (setq args (append args (list "--run-metadata" run-metadata))))
    (apply #'spacelift--run args)))

(defun spacelift--run-logs-process (stack-id run-id buffer tail phase)
  "Stream logs into BUFFER for STACK-ID, returning the process.
When RUN-ID is non-nil, stream that run's logs; otherwise stream the
latest run of the stack (`--run-latest').  When TAIL is non-nil, keep
following the run.  PHASE, when non-nil, restricts the logs to a single
run phase (for example \"PLANNING\" or \"APPLYING\")."
  (let ((args (append (list "stack" "logs" "--id" stack-id)
                      (if run-id
                          (list "--run" run-id)
                        (list "--run-latest")))))
    (when tail
      (setq args (append args (list "--tail"))))
    (when phase
      (setq args (append args (list "--phase" phase))))
    (apply #'spacelift--run-async buffer "spacelift-logs" args)))

(defun spacelift-run-logs-process (run buffer &optional tail phase)
  "Stream the logs of RUN into BUFFER, returning the process.
When TAIL is non-nil, keep following the run as it progresses.  PHASE,
when non-nil, restricts the logs to a single run phase (for example
\"PLANNING\" or \"APPLYING\")."
  (spacelift--run-logs-process (spacelift-run-stack-id run)
                               (spacelift-run-id run)
                               buffer tail phase))

(defun spacelift-stack-latest-logs-process (stack-id buffer &optional tail phase)
  "Stream the latest run logs of STACK-ID into BUFFER, returning the process.
When TAIL is non-nil, keep following the run.  PHASE, when non-nil,
restricts the logs to a single run phase."
  (spacelift--run-logs-process stack-id nil buffer tail phase))

(provide 'spacelift-run)

;;; spacelift-run.el ends here

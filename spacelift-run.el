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
(require 'ansi-color)
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

(defun spacelift-run-owned-p (run)
  "Return non-nil when RUN belongs to the authenticated user."
  (let ((commit (spacelift-run-commit run))
        (same-identity-p
         (lambda (a b)
           (and a b (string-equal (downcase a) (downcase b))))))
    (or (funcall same-identity-p (spacelift-run-triggered-by run)
                 (spacelift-current-user-login))
        (and commit spacelift-vcs-login
             (funcall same-identity-p (spacelift-commit-login commit)
                      spacelift-vcs-login))
        (and commit
             (funcall same-identity-p (spacelift-commit-author commit)
                      (spacelift-current-user-name))))))

(defun spacelift-run-browse-url (run)
  "Return the Spacelift console URL for RUN."
  (spacelift-run-url (spacelift-run-stack-id run) (spacelift-run-id run)))

;;; API

(defun spacelift-stack--blocker-run (stack)
  "Return a lightweight run for STACK's blocker, or nil when unblocked."
  (when (spacelift-stack-blocker-id stack)
    (spacelift-run-create
     :id (spacelift-stack-blocker-id stack)
     :stack-id (spacelift-stack-id stack)
     :state (spacelift-stack-blocker-state stack)
     :branch (spacelift-stack-blocker-branch stack)
     :commit (spacelift-stack-blocker-commit stack))))

(defun spacelift-stack-current-run (stack)
  "Return the run to act on for STACK: its blocking run when blocked.
When STACK is blocked by a run, a lightweight `spacelift-run' is built
from the stack's blocker slots, avoiding a fetch; otherwise the stack's
most recent run is fetched.  This is the run displayed on the stack
line, so acting on it matches what the user sees.

The blocked run's slots are a snapshot from when STACK was last
loaded, not a live fetch: its state may be stale (a write acting on
it is validated server-side by `spacectl'), and the state is nil when
the blocking run's details were unavailable at load time."
  (or (spacelift-stack--blocker-run stack)
      (car (spacelift-stack-run-list (spacelift-stack-id stack) 1))))

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

(defun spacelift-run-discard (run)
  "Discard the unconfirmed tracked RUN via `spacectl stack discard'.
Return `spacectl''s raw output.  This is a write operation."
  (apply #'spacelift--run
         (list "stack" "discard"
               "--id" (spacelift-run-stack-id run)
               "--run" (spacelift-run-id run))))

(defun spacelift-run-retry (run)
  "Retry the failed RUN via `spacectl stack retry'.
Return `spacectl''s raw output.  This is a write operation."
  (apply #'spacelift--run
         (list "stack" "retry"
               "--id" (spacelift-run-stack-id run)
               "--run" (spacelift-run-id run))))

(defun spacelift-run-prioritize (run &optional deprioritize)
  "Prioritize RUN, or deprioritize it when DEPRIORITIZE is non-nil.
Return `spacectl''s raw output.  This is a write operation."
  (apply #'spacelift--run
         (list "stack" (if deprioritize "deprioritize" "prioritize")
               "--id" (spacelift-run-stack-id run)
               "--run" (spacelift-run-id run))))

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

;;; Plan diff

(defconst spacelift-run--plan-header-regexp
  "^ *\\(?:[-+~>]\\{1,2\\} ?\\)?[^ ]+: (\\([a-z-]+\\))"
  "Regexp matching a Pulumi preview resource block header line.
Match group 1 is the operation, e.g. \"update\" or \"same\"; trailing
text after the closing paren (e.g. a lock emoji) is ignored.")

(defvar spacelift-run--plan-diff-cache (make-hash-table :test #'equal)
  "Cache of `spacelift-run--build-plan-diff' results keyed by run id.")

(defun spacelift-run-plan-log (run &optional phase)
  "Return RUN's PHASE log, synchronously, ANSI codes stripped.
PHASE defaults to \"PLANNING\"."
  (ansi-color-filter-apply
   (spacelift--run "stack" "logs"
                   "--id" (spacelift-run-stack-id run)
                   "--run" (spacelift-run-id run)
                   "--phase" (or phase "PLANNING"))))

(defun spacelift-run-failed-phase (run)
  "Return the run phase following the FAILED entry in RUN's history.
History is newest-first, so this is the phase that was running when
RUN failed.  Return nil when RUN's history has no FAILED entry."
  (let* ((data (spacelift--run-graphql
                "query($s: ID!, $r: ID!) { stack(id: $s) { run(id: $r) { history { state } } } }"
                `((s . ,(spacelift-run-stack-id run))
                  (r . ,(spacelift-run-id run)))))
         (history (alist-get 'history (alist-get 'run (alist-get 'stack data))))
         (rest (cl-member-if (lambda (entry) (equal (alist-get 'state entry) "FAILED"))
                             history)))
    (and rest (cadr rest) (alist-get 'state (cadr rest)))))

(defun spacelift-run--strip-color-tags (line)
  "Remove Pulumi `<{%...%}>' color tags from LINE."
  (replace-regexp-in-string "<{%[^%]*%}>" "" line))

(defun spacelift-run--parse-plan-summary (lines)
  "Return the \"Resources:\" summary block from LINES as `(summary . TEXT)'."
  (let ((rest (cl-member-if (lambda (line) (string-prefix-p "Resources:" line))
                            lines))
        (result nil)
        (done nil))
    (while (and rest (not done))
      (if (string-empty-p (string-trim (car rest)))
          (setq done t)
        (push (cons 'summary (car rest)) result)
        (setq rest (cdr rest))))
    (nreverse result)))

;; shortcut: Pulumi preview format only, extend when Terraform stacks appear
(defun spacelift-run--parse-plan-diff (log)
  "Return the list of non-trivial entries parsed from LOG.
LOG is the raw text of a phase log with ANSI codes already stripped.
Each entry is `(KIND . TEXT)' with KIND one of `diff', `error', or
`summary'.  Resource blocks whose operation is \"same\", \"read\", or
\"refresh\" are dropped; the rest are kept as `diff' entries, verbatim
except their `[urn=...]' and `[provider=...]' lines, which add noise
without changing what review needs.  Lines starting with \"error:\" and
their continuation lines become `error' entries.  The final
\"Resources:\" block is appended as `summary' entries when present,
regardless of whether any other entry was kept; right after its
heading come `resource' entries \"OP URN\", one per kept block."
  (let ((lines (mapcar #'spacelift-run--strip-color-tags (split-string log "\n")))
        (result nil)
        (resources nil)
        (op nil)
        (diff-collecting nil)
        (error-collecting nil))
    (dolist (line lines)
      (cond
       ((string-match spacelift-run--plan-header-regexp line)
        (setq error-collecting nil
              diff-collecting (not (member (match-string 1 line)
                                           '("same" "read" "refresh"))))
        (when diff-collecting
          (setq op (if (string-match "^ *\\([-+~>]+\\)" line)
                       (match-string 1 line)
                     "~"))
          (push (cons 'diff line) result)))
       ((string-match-p "^error:" line)
        (setq diff-collecting nil
              error-collecting t)
        (push (cons 'error line) result))
       (error-collecting
        (if (or (string-empty-p (string-trim line))
                (string-prefix-p "Resources:" line))
            (setq error-collecting nil)
          (push (cons 'error line) result)))
       (diff-collecting
        (cond
         ((or (string-empty-p (string-trim line))
              (string-prefix-p "@ " line)
              (string-prefix-p "Resources:" line)
              (not (string-prefix-p " " line)))
          (setq diff-collecting nil))
         ((string-match "^ *\\[urn=\\([^]]+\\)\\]" line)
          (push (cons 'resource (concat op " " (match-string 1 line))) resources))
         ((string-match-p "^ *\\[provider=" line) nil)
         (t (push (cons 'diff line) result))))))
    (let ((summary (spacelift-run--parse-plan-summary lines)))
      (append (nreverse result)
              (and summary (list (car summary)))
              (and summary (nreverse resources))
              (cdr summary)))))

(defun spacelift-run--last-lines-as-errors (log n)
  "Return the last N non-blank lines of LOG as `(error . TEXT)' entries."
  (let* ((lines (cl-remove-if (lambda (l) (string-empty-p (string-trim l)))
                              (mapcar #'spacelift-run--strip-color-tags
                                      (split-string log "\n")))))
    (mapcar (lambda (l) (cons 'error l)) (last lines n))))

(defun spacelift-run--build-plan-diff (run)
  "Build the plan diff entries for RUN; see `spacelift-run-plan-diff'."
  (if (equal (spacelift-run-state run) "FAILED")
      (let* ((phase (or (spacelift-run-failed-phase run) "PLANNING"))
             (log (spacelift-run-plan-log run phase))
             (entries (spacelift-run--parse-plan-diff log)))
        (cons (cons 'error (format "Failed during %s" phase))
              (if (cl-some (lambda (e) (eq (car e) 'error)) entries)
                  entries
                (append entries (spacelift-run--last-lines-as-errors log 20)))))
    (spacelift-run--parse-plan-diff (spacelift-run-plan-log run))))

(defun spacelift-run-plan-diff (run)
  "Return the parsed plan diff entries for RUN, caching per run id.
When RUN's state is \"FAILED\", the log of the phase that failed is
parsed instead of the PLANNING log (falling back to PLANNING when the
failed phase is unknown), and a `(error . \"Failed during PHASE\")'
entry is prepended."
  (let ((id (spacelift-run-id run)))
    (or (gethash id spacelift-run--plan-diff-cache)
        (puthash id (spacelift-run--build-plan-diff run)
                 spacelift-run--plan-diff-cache))))

(provide 'spacelift-run)

;;; spacelift-run.el ends here

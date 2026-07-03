;;; spacelift-worker.el --- Worker pool structs and API for Spacelift -*- lexical-binding: t; -*-

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

;; Runtime representation of Spacelift worker pools, the workers
;; registered to them, and the queue of runs waiting to be scheduled on
;; them (Spacelift's schedulable runs).  Worker pools are listed through
;; `spacectl'; the richer per-pool worker fields and the queue are only
;; exposed by the GraphQL API, so those are fetched with
;; `spacelift--run-graphql'.  Display and interactive logic lives in
;; `spacelift-ui.el'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'spacelift-core)
(require 'spacelift-run)

(cl-defstruct (spacelift-worker-pool
               (:constructor spacelift-worker-pool-create))
  "Runtime representation of a Spacelift worker pool.
Slot RAW holds the original parsed alist."
  id name description pending-runs busy-workers registered-workers
  schedulable-runs-count raw)

(cl-defstruct (spacelift-worker (:constructor spacelift-worker-create))
  "Runtime representation of a single worker in a pool.
METADATA is the parsed metadata alist reported by the worker.  Slot RAW
holds the original parsed alist."
  id busy drained status created-at available-at metadata raw)

(cl-defstruct (spacelift-queued-run (:constructor spacelift-queued-run-create))
  "A run waiting in a worker pool's schedule (the pool's queue).
RUN is the `spacelift-run' scheduled at POSITION.  Slot RAW holds the
original parsed alist."
  position stack-id stack-name run raw)

(defun spacelift-worker-pool--parse (object)
  "Build a `spacelift-worker-pool' from a parsed JSON OBJECT alist."
  (spacelift-worker-pool-create
   :id (spacelift--alist-get 'id object)
   :name (spacelift--alist-get 'name object)
   :description (spacelift--alist-get 'description object)
   :pending-runs (spacelift--alist-get 'pendingRuns object)
   :busy-workers (spacelift--alist-get 'busyWorkers object)
   :registered-workers (spacelift--alist-get 'registeredWorkers object)
   :schedulable-runs-count (spacelift--alist-get 'schedulableRunsCount object)
   :raw object))

(defun spacelift-worker--parse-metadata (value)
  "Return VALUE parsed as an alist when it is a JSON metadata string.
`spacectl' returns worker metadata as an alist already, while the
GraphQL API returns it as a JSON string; both are normalised to an
alist.  Return nil when VALUE is empty or cannot be parsed."
  (cond
   ((null value) nil)
   ((listp value) value)
   ((and (stringp value) (not (string-empty-p value)))
    (condition-case nil
        (let ((json-object-type 'alist)
              (json-key-type 'symbol)
              (json-false nil)
              (json-null nil))
          (json-read-from-string value))
      (error nil)))))

(defun spacelift-worker--parse (object)
  "Build a `spacelift-worker' from a parsed JSON OBJECT alist."
  (spacelift-worker-create
   :id (spacelift--alist-get 'id object)
   :busy (spacelift--alist-get 'busy object)
   :drained (spacelift--alist-get 'drained object)
   :status (spacelift--alist-get 'status object)
   :created-at (spacelift--alist-get 'createdAt object)
   :available-at (spacelift--alist-get 'availableAt object)
   :metadata (spacelift-worker--parse-metadata
              (spacelift--alist-get 'metadata object))
   :raw object))

(defun spacelift-queued-run--parse (object)
  "Build a `spacelift-queued-run' from a schedulable-run node OBJECT alist.
The nested run is parsed into a `spacelift-run' threaded with its stack
id so its console URL and logs can be reached."
  (let ((stack-id (spacelift--alist-get 'stackId object)))
    (spacelift-queued-run-create
     :position (spacelift--alist-get 'position object)
     :stack-id stack-id
     :stack-name (spacelift--alist-get 'stackName object)
     :run (spacelift-run--parse (spacelift--alist-get 'run object) stack-id)
     :raw object)))

(defun spacelift-worker-metadata-value (worker key)
  "Return the metadata value for KEY (a symbol) of WORKER, or nil."
  (spacelift--alist-get key (spacelift-worker-metadata worker)))

;;; API

(defun spacelift-worker-pool-list ()
  "Return the Spacelift worker pools as a list of `spacelift-worker-pool'.
The returned pools are sorted case-insensitively by name."
  (seq-sort-by (lambda (pool) (downcase (or (spacelift-worker-pool-name pool) "")))
               #'string-lessp
               (mapcar #'spacelift-worker-pool--parse
                       (spacelift--run-json "workerpool" "list"))))

(defun spacelift-worker-pool-worker-list (pool-id)
  "Return the workers of the pool identified by POOL-ID.
Each element is a `spacelift-worker'.  The GraphQL API is used so that
the worker status and timestamps, absent from the `spacectl' listing,
are available."
  (let* ((data (spacelift--run-graphql
                (concat "query($id: ID!) { workerPool(id: $id) { "
                        "workers { id busy drained status createdAt "
                        "availableAt metadata } } }")
                `((id . ,pool-id))))
         (pool (spacelift--alist-get 'workerPool data)))
    (mapcar #'spacelift-worker--parse
            (spacelift--alist-get 'workers pool))))

(defun spacelift-worker-pool-queue (pool-id &optional limit)
  "Return the queued runs of the pool identified by POOL-ID.
Each element is a `spacelift-queued-run', ordered by schedule position.
LIMIT, when non-nil, caps the number of queued runs fetched."
  (let* ((data (spacelift--run-graphql
                (concat "query($id: ID!, $first: Int) { workerPool(id: $id) { "
                        "searchSchedulableRuns(input: { first: $first }) { "
                        "edges { node { position stackId stackName "
                        "run { id state title branch createdAt triggeredBy "
                        "delta { addCount changeCount deleteCount } } } } } } }")
                `((id . ,pool-id) (first . ,(or limit 50)))))
         (pool (spacelift--alist-get 'workerPool data))
         (search (spacelift--alist-get 'searchSchedulableRuns pool)))
    (mapcar (lambda (edge)
              (spacelift-queued-run--parse (spacelift--alist-get 'node edge)))
            (spacelift--alist-get 'edges search))))

(provide 'spacelift-worker)

;;; spacelift-worker.el ends here

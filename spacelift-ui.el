;;; spacelift-ui.el --- Display and interactive UI for Spacelift -*- lexical-binding: t; -*-

;; Copyright (C) 2026 drlkf

;; Author: drlkf <drlkf@drlkf.net>
;; Assisted-by: Claude:claude-opus-4-8
;; Keywords: tools, processes
;; Package-Requires: ((emacs "27.1") (transient "0.3.0"))
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

;; Interactive buffers and major modes for browsing Spacelift stacks and
;; their runs.
;;
;; Five read-only buffers are provided:
;;
;; - The stack list buffer (`spacelift-stack-list-mode'), one line per
;;   stack, formatted according to `spacelift-stack-line-format'.  Press
;;   RET on a stack to open its detail buffer, or `R' for its runs.
;;
;; - The stack detail buffer (`spacelift-stack-mode'), showing all
;;   available stack information in a readable layout.
;;
;; - The run list buffer (`spacelift-run-list-mode'), one line per run,
;;   formatted according to `spacelift-run-line-format'.  Press RET on a
;;   run to open its detail buffer, or `l' to view its logs.
;;
;; - The run detail buffer (`spacelift-run-mode'), showing all available
;;   run information.
;;
;; - The run log buffer (`spacelift-run-log-mode'), streaming the logs of
;;   a run with ANSI colors, optionally tailing it.
;;
;; In every buffer, `r' reloads the contents and `q' quits the window.
;; `w' browses the Spacelift console URL of the stack or run at point, and
;; `?' shows a magit-style transient popup of the available keys.

;;; Code:

(require 'cl-lib)
(require 'ansi-color)
(require 'browse-url)
(require 'transient)
(require 'spacelift-core)
(require 'spacelift-stack)
(require 'spacelift-run)

;;; Faces

(defface spacelift-state-finished-face
  '((t :inherit success))
  "Face for a finished stack state."
  :group 'spacelift)

(defface spacelift-state-failed-face
  '((t :inherit error))
  "Face for a failed stack state."
  :group 'spacelift)

(defface spacelift-state-progress-face
  '((t :inherit warning))
  "Face for an in-progress stack state."
  :group 'spacelift)

(defface spacelift-label-face
  '((t :inherit font-lock-constant-face))
  "Face for stack labels."
  :group 'spacelift)

(defface spacelift-heading-face
  '((t :inherit font-lock-keyword-face))
  "Face for section headings in detail buffers."
  :group 'spacelift)

(defface spacelift-field-face
  '((t :inherit font-lock-function-name-face))
  "Face for field names in detail buffers."
  :group 'spacelift)

;;; Customization

(defcustom spacelift-stack-line-format "%-30n  %-10s  %-20p  %l"
  "Format string for a stack line in the stack list buffer.
The following `format-spec' style specifiers are available:

  %n  stack name
  %i  stack id (slug)
  %s  current state
  %b  tracked branch
  %p  worker pool name
  %r  repository
  %S  space name
  %d  description
  %l  comma-separated labels

Width and alignment flags (e.g. %-30n) are supported."
  :type 'string
  :group 'spacelift)

(defcustom spacelift-stack-list-buffer-name "*spacelift-stacks*"
  "Name of the buffer used to list stacks."
  :type 'string
  :group 'spacelift)

(defcustom spacelift-run-line-format "%-12c  %-12s  %-19d  %t"
  "Format string for a run line in the run list buffer.
The following `format-spec' style specifiers are available:

  %i  run id
  %s  current state
  %t  run title
  %b  branch
  %c  short commit hash
  %a  commit author
  %d  creation date
  %T  trigger source
  %D  resource delta (added/changed/deleted)

Width and alignment flags (e.g. %-12s) are supported."
  :type 'string
  :group 'spacelift)

(defcustom spacelift-run-list-max-results 20
  "Default maximum number of runs fetched for a run list buffer."
  :type 'integer
  :group 'spacelift)

;;; State

(defvar-local spacelift--stack nil
  "The `spacelift-stack' displayed in the current detail buffer.")

(defvar-local spacelift--list-search nil
  "Search string used to populate the current stack list buffer.")

(defvar-local spacelift--list-limit nil
  "Limit used to populate the current stack list buffer.")

(defvar-local spacelift--run nil
  "The `spacelift-run' displayed in the current run detail buffer.")

(defvar-local spacelift--run-stack-id nil
  "Stack id whose runs populate the current run list buffer.")

(defvar-local spacelift--run-max-results nil
  "Maximum number of runs fetched for the current run list buffer.")

;;; Formatting helpers

(defun spacelift--state-face (state)
  "Return a face symbol appropriate for STATE."
  (pcase state
    ("FINISHED" 'spacelift-state-finished-face)
    ((or "FAILED" "STOPPED" "CANCELED" "DISCARDED") 'spacelift-state-failed-face)
    ((or "INITIALIZING" "PLANNING" "APPLYING" "PREPARING" "QUEUED"
         "CONFIRMED" "UNCONFIRMED" "PENDING_REVIEW")
     'spacelift-state-progress-face)
    (_ 'default)))

(defun spacelift--propertize-state (state)
  "Return STATE propertized with its state face."
  (let ((value (or state "")))
    (propertize value 'face (spacelift--state-face state))))

(defun spacelift--format-labels (labels)
  "Return LABELS, a list of strings, joined and propertized."
  (mapconcat (lambda (label)
               (propertize label 'face 'spacelift-label-face))
             labels ", "))

(defun spacelift--stack-line (stack)
  "Render STACK into a single display line using `spacelift-stack-line-format'."
  (format-spec
   spacelift-stack-line-format
   `((?n . ,(or (spacelift-stack-name stack) ""))
     (?i . ,(or (spacelift-stack-id stack) ""))
     (?s . ,(spacelift--propertize-state (spacelift-stack-state stack)))
     (?b . ,(or (spacelift-stack-branch stack) ""))
     (?p . ,(or (spacelift-stack-worker-pool-name stack) ""))
     (?r . ,(or (spacelift-stack-repository stack) ""))
     (?S . ,(or (spacelift-stack-space-name stack) ""))
     (?d . ,(or (spacelift-stack-description stack) ""))
     (?l . ,(spacelift--format-labels (spacelift-stack-labels stack))))))

(defun spacelift--run-line (run)
  "Render RUN into a single display line using `spacelift-run-line-format'."
  (let ((commit (spacelift-run-commit run)))
    (format-spec
     spacelift-run-line-format
     `((?i . ,(or (spacelift-run-id run) ""))
       (?s . ,(spacelift--propertize-state (spacelift-run-state run)))
       (?t . ,(or (spacelift-run-title run) ""))
       (?b . ,(or (spacelift-run-branch run) ""))
       (?c . ,(let ((hash (and commit (spacelift-commit-hash commit))))
                (if hash (substring hash 0 (min 8 (length hash))) "")))
       (?a . ,(or (and commit (or (spacelift-commit-author commit)
                                  (spacelift-commit-login commit)))
                  ""))
       (?d . ,(spacelift--format-unix-time (spacelift-run-created-at run)))
       (?T . ,(or (spacelift-run-triggered-by run) ""))
       (?D . ,(or (spacelift-run-delta run) ""))))))

;;; Help

;; A magit-style transient popup lists the available keys for the current
;; buffer, grouped by purpose.  Each mode has its own prefix, and
;; `spacelift-help' dispatches to the right one.

(transient-define-prefix spacelift-stack-list-help ()
  "Show the available keys in a Spacelift stack list buffer."
  ["Spacelift stacks"
   ["Navigate"
    ("RET" "Visit stack" spacelift-stack-list-visit)
    ("R" "List runs" spacelift-stack-list-runs)
    ("j" "Next line" next-line :transient t)
    ("k" "Previous line" previous-line :transient t)]
   ["Act"
    ("w" "Browse in console" spacelift-stack-list-browse)
    ("l" "View latest logs" spacelift-stack-list-latest-logs)
    ("r" "Reload" spacelift-stack-list-refresh)]
   ["Window"
    ("q" "Quit window" quit-window)
    ("?" "Close help" transient-quit-one)]])

(transient-define-prefix spacelift-stack-help ()
  "Show the available keys in a Spacelift stack detail buffer."
  ["Spacelift stack"
   ["Navigate"
    ("R" "List runs" spacelift-stack-runs)]
   ["Act"
    ("w" "Browse in console" spacelift-stack-browse)
    ("l" "View latest logs" spacelift-stack-latest-logs)
    ("r" "Reload" spacelift-stack-refresh)]
   ["Window"
    ("q" "Quit window" quit-window)
    ("?" "Close help" transient-quit-one)]])

(transient-define-prefix spacelift-run-list-help ()
  "Show the available keys in a Spacelift run list buffer."
  ["Spacelift runs"
   ["Navigate"
    ("RET" "Visit run" spacelift-run-list-visit)
    ("j" "Next line" next-line :transient t)
    ("k" "Previous line" previous-line :transient t)]
   ["Act"
    ("w" "Browse run URL" spacelift-run-browse)
    ("l" "View logs" spacelift-run-logs)
    ("r" "Reload" spacelift-run-list-refresh)]
   ["Window"
    ("q" "Quit window" quit-window)
    ("?" "Close help" transient-quit-one)]])

(transient-define-prefix spacelift-run-help ()
  "Show the available keys in a Spacelift run detail buffer."
  ["Spacelift run"
   ["Act"
    ("w" "Browse run URL" spacelift-run-browse)
    ("l" "View logs" spacelift-run-logs)
    ("r" "Reload" spacelift-run-refresh)]
   ["Window"
    ("q" "Quit window" quit-window)
    ("?" "Close help" transient-quit-one)]])

(transient-define-prefix spacelift-run-log-help ()
  "Show the available keys in a Spacelift run log buffer."
  ["Spacelift run logs"
   ["Act"
    ("w" "Browse in console" spacelift-run-log-browse)
    ("r" "Reload logs" spacelift-run-log-refresh)
    ("G" "Toggle tailing" spacelift-run-log-tail)]
   ["Window"
    ("q" "Quit window" spacelift-run-log-quit)
    ("?" "Close help" transient-quit-one)]])

(defun spacelift-help ()
  "Show a magit-style popup of the available keys for the current buffer."
  (interactive)
  (call-interactively
   (cond
    ((derived-mode-p 'spacelift-stack-list-mode) #'spacelift-stack-list-help)
    ((derived-mode-p 'spacelift-stack-mode) #'spacelift-stack-help)
    ((derived-mode-p 'spacelift-run-list-mode) #'spacelift-run-list-help)
    ((derived-mode-p 'spacelift-run-mode) #'spacelift-run-help)
    ((derived-mode-p 'spacelift-run-log-mode) #'spacelift-run-log-help)
    (t (user-error "Not in a Spacelift buffer")))))

;;; Stack list buffer

(defvar spacelift-stack-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'spacelift-stack-list-visit)
    (define-key map (kbd "R") #'spacelift-stack-list-runs)
    (define-key map (kbd "w") #'spacelift-stack-list-browse)
    (define-key map (kbd "l") #'spacelift-stack-list-latest-logs)
    (define-key map (kbd "r") #'spacelift-stack-list-refresh)
    (define-key map (kbd "g") #'spacelift-stack-list-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "?") #'spacelift-help)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    map)
  "Keymap for `spacelift-stack-list-mode'.")

(define-derived-mode spacelift-stack-list-mode special-mode "Spacelift-Stacks"
  "Major mode for listing Spacelift stacks.

\\{spacelift-stack-list-mode-map}"
  (setq-local truncate-lines t)
  (hl-line-mode 1))

(defun spacelift--insert-stack-list (stacks)
  "Insert STACKS into the current buffer, one per line."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (if (null stacks)
        (insert (propertize "No stacks found.\n" 'face 'shadow))
      (dolist (stack stacks)
        (insert (propertize (spacelift--stack-line stack)
                            'spacelift-stack stack)
                "\n")))
    (goto-char (point-min))))

(defun spacelift-stack-list-refresh ()
  "Reload the stacks shown in the current stack list buffer."
  (interactive)
  (unless (derived-mode-p 'spacelift-stack-list-mode)
    (user-error "Not in a Spacelift stack list buffer"))
  (spacelift-with-auth
    (let ((stacks (spacelift-stack-list spacelift--list-search
                                        spacelift--list-limit))
          (line (line-number-at-pos)))
      (spacelift--insert-stack-list stacks)
      (forward-line (1- line))
      (message "Loaded %d stack(s)" (length stacks)))))

(defun spacelift-stack-list-stack-at-point ()
  "Return the `spacelift-stack' on the current line, or nil."
  (get-text-property (line-beginning-position) 'spacelift-stack))

(defun spacelift-stack-list-visit ()
  "Open the detail buffer for the stack on the current line."
  (interactive)
  (let ((stack (spacelift-stack-list-stack-at-point)))
    (unless stack
      (user-error "No stack on this line"))
    (spacelift-stack-show-buffer (spacelift-stack-id stack))))

(defun spacelift-stack-list-runs ()
  "Open the run list buffer for the stack on the current line."
  (interactive)
  (let ((stack (spacelift-stack-list-stack-at-point)))
    (unless stack
      (user-error "No stack on this line"))
    (spacelift-run-list-buffer (spacelift-stack-id stack))))

(defun spacelift-stack-list-browse ()
  "Open the Spacelift console page for the stack on the current line."
  (interactive)
  (let ((stack (spacelift-stack-list-stack-at-point)))
    (unless stack
      (user-error "No stack on this line"))
    (spacelift-with-auth
      (browse-url (spacelift-stack-url (spacelift-stack-id stack))))))

(defun spacelift-stack-list-latest-logs (&optional tail)
  "View the latest run logs of the stack on the current line.
With a prefix argument TAIL, follow the run as it progresses."
  (interactive "P")
  (let ((stack (spacelift-stack-list-stack-at-point)))
    (unless stack
      (user-error "No stack on this line"))
    (spacelift-with-auth
      (spacelift-stack-show-latest-logs (spacelift-stack-id stack) tail))))

;;;###autoload
(defun spacelift-stack-list-stacks (&optional search limit)
  "Display the list of Spacelift stacks in a dedicated buffer.
With a prefix argument, prompt for a full-text SEARCH string.  LIMIT,
when called from Lisp, caps the number of stacks fetched.

When `spacectl' is not authenticated, offer to log in instead."
  (interactive
   (when current-prefix-arg
     (list (read-string "Search stacks: ") nil)))
  (spacelift-with-auth
    (let ((stacks (spacelift-stack-list search limit))
          (buffer (get-buffer-create spacelift-stack-list-buffer-name)))
      (with-current-buffer buffer
        (spacelift-stack-list-mode)
        (setq spacelift--list-search search
              spacelift--list-limit limit)
        (spacelift--insert-stack-list stacks))
      (pop-to-buffer buffer))))

;;; Stack detail buffer

(defvar spacelift-stack-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "R") #'spacelift-stack-runs)
    (define-key map (kbd "w") #'spacelift-stack-browse)
    (define-key map (kbd "l") #'spacelift-stack-latest-logs)
    (define-key map (kbd "r") #'spacelift-stack-refresh)
    (define-key map (kbd "g") #'spacelift-stack-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "?") #'spacelift-help)
    map)
  "Keymap for `spacelift-stack-mode'.")

(define-derived-mode spacelift-stack-mode special-mode "Spacelift-Stack"
  "Major mode for showing a single Spacelift stack.

\\{spacelift-stack-mode-map}"
  (setq-local truncate-lines nil))

;;; Evil integration

;; `special-mode' buffers are placed in evil's motion state, where evil's
;; own bindings (e.g. `g', `q') shadow the major-mode keymaps.  When evil
;; is available, rebind the keys in the relevant states so the bindings
;; work for evil users without adding a hard dependency on evil.

(declare-function evil-define-key* "ext:evil-core")

(defun spacelift--setup-evil-bindings ()
  "Bind the Spacelift keys in evil states, when evil is available."
  ;; `g' is intentionally left unbound here so evil's `g'-prefixed
  ;; motions (e.g. `gg') keep working; `r' is the primary reload key.
  (when (fboundp 'evil-define-key*)
    (evil-define-key* '(motion normal) spacelift-stack-list-mode-map
      (kbd "RET") #'spacelift-stack-list-visit
      "r" #'spacelift-stack-list-refresh
      "q" #'quit-window
      "?" #'spacelift-help)
    (evil-define-key* '(motion normal) spacelift-stack-mode-map
      "r" #'spacelift-stack-refresh
      "q" #'quit-window
      "?" #'spacelift-help)))

(with-eval-after-load 'evil
  (spacelift--setup-evil-bindings))

(defun spacelift--detail-buffer-name (id)
  "Return the detail buffer name for stack ID."
  (format "*spacelift-stack: %s*" id))

(defun spacelift--insert-heading (text)
  "Insert TEXT as a section heading."
  (insert (propertize text 'face 'spacelift-heading-face) "\n"))

(defun spacelift--insert-field (name value)
  "Insert a NAME: VALUE field line when VALUE is non-empty."
  (let ((string (cond ((null value) "")
                      ((stringp value) value)
                      ((eq value t) "yes")
                      (t (format "%s" value)))))
    (unless (string-empty-p string)
      (insert "  "
              (propertize (format "%-16s" (concat name ":"))
                          'face 'spacelift-field-face)
              string
              "\n"))))

(defun spacelift--insert-commit (commit)
  "Insert COMMIT details, when non-nil."
  (when commit
    (spacelift--insert-heading "Tracked commit")
    (spacelift--insert-field "Hash" (spacelift-commit-hash commit))
    (spacelift--insert-field "Author" (or (spacelift-commit-author commit)
                                          (spacelift-commit-login commit)))
    (spacelift--insert-field "Message" (spacelift-commit-message commit))
    (spacelift--insert-field
     "Date" (spacelift--format-unix-time (spacelift-commit-timestamp commit)))
    (spacelift--insert-field "URL" (spacelift-commit-url commit))
    (insert "\n")))

(defun spacelift--insert-stack-detail (stack)
  "Render STACK into the current detail buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (or (spacelift-stack-name stack)
                            (spacelift-stack-id stack))
                        'face '(spacelift-heading-face (:height 1.2)))
            "  "
            (spacelift--propertize-state (spacelift-stack-state stack))
            "\n\n")

    (spacelift--insert-heading "General")
    (spacelift--insert-field "ID" (spacelift-stack-id stack))
    (spacelift--insert-field "Description" (spacelift-stack-description stack))
    (spacelift--insert-field "Space" (spacelift-stack-space-name stack))
    (spacelift--insert-field "Vendor" (spacelift-stack-vendor stack))
    (spacelift--insert-field "Worker pool" (spacelift-stack-worker-pool-name stack))
    (spacelift--insert-field "Autodeploy" (spacelift-stack-autodeploy stack))
    (spacelift--insert-field "Locked" (spacelift-stack-locked stack))
    (spacelift--insert-field
     "Created" (spacelift--format-unix-time (spacelift-stack-created-at stack)))
    (spacelift--insert-field
     "State set" (spacelift--format-unix-time (spacelift-stack-state-set-at stack)))
    (insert "\n")

    (spacelift--insert-heading "Source")
    (spacelift--insert-field "Provider" (spacelift-stack-provider stack))
    (spacelift--insert-field "Repository" (spacelift-stack-repository stack))
    (spacelift--insert-field "Namespace" (spacelift-stack-namespace stack))
    (spacelift--insert-field "Branch" (spacelift-stack-branch stack))
    (spacelift--insert-field "Project root" (spacelift-stack-project-root stack))
    (insert "\n")

    (when (spacelift-stack-labels stack)
      (spacelift--insert-heading "Labels")
      (insert "  " (spacelift--format-labels (spacelift-stack-labels stack))
              "\n\n"))

    (spacelift--insert-commit (spacelift-stack-tracked-commit stack))
    (goto-char (point-min))))

(defun spacelift-stack-refresh ()
  "Reload the stack shown in the current detail buffer."
  (interactive)
  (unless (and (derived-mode-p 'spacelift-stack-mode) spacelift--stack)
    (user-error "Not in a Spacelift stack buffer"))
  (spacelift-with-auth
    (let ((stack (spacelift-stack-show (spacelift-stack-id spacelift--stack))))
      (setq spacelift--stack stack)
      (spacelift--insert-stack-detail stack)
      (message "Reloaded stack %s" (spacelift-stack-id stack)))))

(defun spacelift-stack-runs ()
  "Open the run list buffer for the stack in the current detail buffer."
  (interactive)
  (unless (and (derived-mode-p 'spacelift-stack-mode) spacelift--stack)
    (user-error "Not in a Spacelift stack buffer"))
  (spacelift-run-list-buffer (spacelift-stack-id spacelift--stack)))

(defun spacelift-stack-browse ()
  "Open the Spacelift console page for the stack in the current detail buffer."
  (interactive)
  (unless (and (derived-mode-p 'spacelift-stack-mode) spacelift--stack)
    (user-error "Not in a Spacelift stack buffer"))
  (spacelift-with-auth
    (browse-url (spacelift-stack-url (spacelift-stack-id spacelift--stack)))))

(defun spacelift-stack-latest-logs (&optional tail)
  "View the latest run logs of the stack in the current detail buffer.
With a prefix argument TAIL, follow the run as it progresses."
  (interactive "P")
  (unless (and (derived-mode-p 'spacelift-stack-mode) spacelift--stack)
    (user-error "Not in a Spacelift stack buffer"))
  (spacelift-with-auth
    (spacelift-stack-show-latest-logs (spacelift-stack-id spacelift--stack)
                                      tail)))

;;;###autoload
(defun spacelift-stack-show-buffer (id)
  "Display detailed information about the stack identified by ID.

When `spacectl' is not authenticated, offer to log in instead."
  (interactive "sStack id: ")
  (spacelift-with-auth
    (let ((stack (spacelift-stack-show id))
          (buffer (get-buffer-create (spacelift--detail-buffer-name id))))
      (with-current-buffer buffer
        (spacelift-stack-mode)
        (setq spacelift--stack stack)
        (spacelift--insert-stack-detail stack))
      (pop-to-buffer buffer))))

;;; Run list buffer

(defvar spacelift-run-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'spacelift-run-list-visit)
    (define-key map (kbd "w") #'spacelift-run-browse)
    (define-key map (kbd "l") #'spacelift-run-logs)
    (define-key map (kbd "r") #'spacelift-run-list-refresh)
    (define-key map (kbd "g") #'spacelift-run-list-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "?") #'spacelift-help)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    map)
  "Keymap for `spacelift-run-list-mode'.")

(define-derived-mode spacelift-run-list-mode special-mode "Spacelift-Runs"
  "Major mode for listing the runs of a Spacelift stack.

\\{spacelift-run-list-mode-map}"
  (setq-local truncate-lines t)
  (hl-line-mode 1))

(defun spacelift--run-list-buffer-name (stack-id)
  "Return the run list buffer name for STACK-ID."
  (format "*spacelift-runs: %s*" stack-id))

(defun spacelift--insert-run-list (run-list)
  "Insert each run of RUN-LIST into the current buffer, one per line."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (if (null run-list)
        (insert (propertize "No runs found.\n" 'face 'shadow))
      (dolist (run run-list)
        (insert (propertize (spacelift--run-line run)
                            'spacelift-run run)
                "\n")))
    (goto-char (point-min))))

(defun spacelift-run-list-run-at-point ()
  "Return the `spacelift-run' on the current line, or nil."
  (get-text-property (line-beginning-position) 'spacelift-run))

(defun spacelift-run-list-refresh ()
  "Reload the run list shown in the current buffer."
  (interactive)
  (unless (and (derived-mode-p 'spacelift-run-list-mode) spacelift--run-stack-id)
    (user-error "Not in a Spacelift run list buffer"))
  (spacelift-with-auth
    (let ((runs (spacelift-stack-run-list spacelift--run-stack-id
                                          spacelift--run-max-results))
          (line (line-number-at-pos)))
      (spacelift--insert-run-list runs)
      (forward-line (1- line))
      (message "Loaded %d run(s)" (length runs)))))

(defun spacelift-run-list-visit ()
  "Open the detail buffer for the run on the current line."
  (interactive)
  (let ((run (spacelift-run-list-run-at-point)))
    (unless run
      (user-error "No run on this line"))
    (spacelift-run-show-buffer run)))

;;;###autoload
(defun spacelift-run-list-buffer (stack-id &optional max-results)
  "Display in a buffer the run list of the stack identified by STACK-ID.
MAX-RESULTS caps the number of runs fetched, defaulting to
`spacelift-run-list-max-results'.

When `spacectl' is not authenticated, offer to log in instead."
  (interactive "sStack id: ")
  (let ((max-results (or max-results spacelift-run-list-max-results)))
    (spacelift-with-auth
      (let ((runs (spacelift-stack-run-list stack-id max-results))
            (buffer (get-buffer-create
                     (spacelift--run-list-buffer-name stack-id))))
        (with-current-buffer buffer
          (spacelift-run-list-mode)
          (setq spacelift--run-stack-id stack-id
                spacelift--run-max-results max-results)
          (spacelift--insert-run-list runs))
        (pop-to-buffer buffer)))))

;;; Run detail buffer

(defvar spacelift-run-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "w") #'spacelift-run-browse)
    (define-key map (kbd "l") #'spacelift-run-logs)
    (define-key map (kbd "r") #'spacelift-run-refresh)
    (define-key map (kbd "g") #'spacelift-run-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "?") #'spacelift-help)
    map)
  "Keymap for `spacelift-run-mode'.")

(define-derived-mode spacelift-run-mode special-mode "Spacelift-Run"
  "Major mode for showing a single Spacelift run.

\\{spacelift-run-mode-map}"
  (setq-local truncate-lines nil))

(defun spacelift--run-detail-buffer-name (run)
  "Return the detail buffer name for RUN."
  (format "*spacelift-run: %s*" (spacelift-run-id run)))

(defun spacelift--insert-run-detail (run)
  "Render RUN into the current detail buffer."
  (let ((inhibit-read-only t)
        (commit (spacelift-run-commit run)))
    (erase-buffer)
    (insert (propertize (or (spacelift-run-title run)
                            (spacelift-run-id run))
                        'face '(spacelift-heading-face (:height 1.2)))
            "  "
            (spacelift--propertize-state (spacelift-run-state run))
            "\n\n")

    (spacelift--insert-heading "General")
    (spacelift--insert-field "ID" (spacelift-run-id run))
    (spacelift--insert-field "Stack" (spacelift-run-stack-id run))
    (spacelift--insert-field "Branch" (spacelift-run-branch run))
    (spacelift--insert-field "Triggered by" (spacelift-run-triggered-by run))
    (spacelift--insert-field "Needs approval" (spacelift-run-needs-approval run))
    (spacelift--insert-field "Drift detection"
                             (spacelift-run-drift-detection run))
    (spacelift--insert-field "Most recent" (spacelift-run-most-recent run))
    (spacelift--insert-field "Resources" (spacelift-run-delta run))
    (spacelift--insert-field
     "Created" (spacelift--format-unix-time (spacelift-run-created-at run)))
    (spacelift--insert-field "URL" (spacelift-run-browse-url run))
    (insert "\n")

    (spacelift--insert-commit commit)
    (goto-char (point-min))))

(defun spacelift-run-refresh ()
  "Reload the run shown in the current detail buffer."
  (interactive)
  (unless (and (derived-mode-p 'spacelift-run-mode) spacelift--run)
    (user-error "Not in a Spacelift run buffer"))
  (spacelift-with-auth
    (let* ((stack-id (spacelift-run-stack-id spacelift--run))
           (id (spacelift-run-id spacelift--run))
           (run (cl-find id (spacelift-stack-run-list
                             stack-id spacelift--run-max-results)
                         :key #'spacelift-run-id :test #'equal)))
      (unless run
        (user-error "Run %s is no longer listed for stack %s" id stack-id))
      (setq spacelift--run run)
      (spacelift--insert-run-detail run)
      (message "Reloaded run %s" id))))

;;;###autoload
(defun spacelift-run-show-buffer (run)
  "Display detailed information about RUN in a dedicated buffer."
  (let ((buffer (get-buffer-create (spacelift--run-detail-buffer-name run))))
    (with-current-buffer buffer
      (spacelift-run-mode)
      (setq spacelift--run run
            spacelift--run-max-results (or spacelift--run-max-results
                                           spacelift-run-list-max-results))
      (spacelift--insert-run-detail run))
    (pop-to-buffer buffer)))

(defun spacelift--run-at-point-or-current ()
  "Return the run targeted by a browse command, or nil.
This is the run on the current line in a run list buffer, or the run
displayed in the current run detail buffer."
  (or (and (derived-mode-p 'spacelift-run-list-mode)
           (spacelift-run-list-run-at-point))
      (and (derived-mode-p 'spacelift-run-mode) spacelift--run)))

(defun spacelift-run-browse ()
  "Browse the Spacelift console URL of the run at point or current buffer.
Works on the run under point in a run list buffer, and on the run
displayed in a run detail buffer."
  (interactive)
  (let ((run (spacelift--run-at-point-or-current)))
    (unless run
      (user-error "No run at point or in the current buffer"))
    (spacelift-with-auth
      (let ((url (spacelift-run-browse-url run)))
        (browse-url url)
        (message "Browsing %s" url)))))

;;; Run log buffer

(defvar-local spacelift--log-stack-id nil
  "Stack id whose run logs populate the current log buffer.")

(defvar-local spacelift--log-run nil
  "The `spacelift-run' whose logs populate the current log buffer.
Nil when the buffer streams the stack's latest run via `--run-latest'.")

(defvar-local spacelift--log-tail nil
  "Whether the current log buffer is following (tailing) the run.")

(defvar spacelift-run-log-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "w") #'spacelift-run-log-browse)
    (define-key map (kbd "r") #'spacelift-run-log-refresh)
    (define-key map (kbd "g") #'spacelift-run-log-refresh)
    (define-key map (kbd "G") #'spacelift-run-log-tail)
    (define-key map (kbd "q") #'spacelift-run-log-quit)
    (define-key map (kbd "?") #'spacelift-help)
    map)
  "Keymap for `spacelift-run-log-mode'.")

(define-derived-mode spacelift-run-log-mode special-mode "Spacelift-Log"
  "Major mode for showing the logs of a Spacelift run.

\\{spacelift-run-log-mode-map}"
  (setq-local truncate-lines nil))

(defun spacelift--run-log-buffer-name (stack-id run)
  "Return the log buffer name for RUN under STACK-ID.
When RUN is nil, the buffer name refers to the stack's latest run."
  (if run
      (format "*spacelift-log: %s*" (spacelift-run-id run))
    (format "*spacelift-log: %s (latest)*" stack-id)))

(defun spacelift--run-log-filter (process string)
  "Insert STRING from PROCESS into its buffer, applying ANSI colors."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (at-end (= (point) (point-max)))
              (windows (get-buffer-window-list buffer nil t)))
          (save-excursion
            (goto-char (point-max))
            (let ((start (point)))
              (insert string)
              (ansi-color-apply-on-region start (point))))
          ;; Follow output when point was already at the end.
          (when at-end
            (goto-char (point-max))
            (dolist (window windows)
              (set-window-point window (point-max)))))))))

(defun spacelift--run-log-sentinel (process _event)
  "Report completion of the log PROCESS in its buffer."
  (let ((buffer (process-buffer process)))
    (when (and (buffer-live-p buffer)
               (memq (process-status process) '(exit signal)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (insert (propertize "\n-- end of logs --\n" 'face 'shadow))))))))

(defun spacelift--run-log-start (stack-id run buffer tail)
  "Start streaming logs into BUFFER, following when TAIL is non-nil.
When RUN is non-nil, stream that run's logs; otherwise stream the latest
run of STACK-ID."
  (let ((existing (get-buffer-process buffer)))
    (when (and existing (process-live-p existing))
      (delete-process existing)))
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize
               (format "Logs for %s (stack %s)%s\n\n"
                       (if run (spacelift-run-id run) "latest run")
                       stack-id
                       (if tail " [tailing]" ""))
               'face 'shadow))))
  (let ((process (if run
                     (spacelift-run-logs-process run buffer tail)
                   (spacelift-stack-latest-logs-process stack-id buffer tail))))
    (set-process-filter process #'spacelift--run-log-filter)
    (set-process-sentinel process #'spacelift--run-log-sentinel)
    process))

(defun spacelift-run-log-refresh ()
  "Reload the logs shown in the current run log buffer."
  (interactive)
  (unless (and (derived-mode-p 'spacelift-run-log-mode) spacelift--log-stack-id)
    (user-error "Not in a Spacelift run log buffer"))
  (spacelift-with-auth
    (spacelift--run-log-start spacelift--log-stack-id spacelift--log-run
                              (current-buffer) spacelift--log-tail)
    (message "Reloading logs for %s"
             (if spacelift--log-run
                 (spacelift-run-id spacelift--log-run)
               (format "latest run of %s" spacelift--log-stack-id)))))

(defun spacelift-run-log-tail ()
  "Toggle following (tailing) the run in the current log buffer."
  (interactive)
  (unless (and (derived-mode-p 'spacelift-run-log-mode) spacelift--log-stack-id)
    (user-error "Not in a Spacelift run log buffer"))
  (setq spacelift--log-tail (not spacelift--log-tail))
  (spacelift-with-auth
    (spacelift--run-log-start spacelift--log-stack-id spacelift--log-run
                              (current-buffer) spacelift--log-tail))
  (message "Log tailing %s" (if spacelift--log-tail "enabled" "disabled")))

(defun spacelift-run-log-browse ()
  "Browse the Spacelift console URL for the current log buffer.
Opens the run URL when known, or the stack URL for a latest-run buffer."
  (interactive)
  (unless (and (derived-mode-p 'spacelift-run-log-mode) spacelift--log-stack-id)
    (user-error "Not in a Spacelift run log buffer"))
  (spacelift-with-auth
    (let ((url (if spacelift--log-run
                   (spacelift-run-browse-url spacelift--log-run)
                 (spacelift-stack-url spacelift--log-stack-id))))
      (browse-url url)
      (message "Browsing %s" url))))

(defun spacelift-run-log-quit ()
  "Stop any running log process and quit the log window."
  (interactive)
  (let ((process (get-buffer-process (current-buffer))))
    (when (and process (process-live-p process))
      (delete-process process)))
  (quit-window))

;;;###autoload
(defun spacelift-run-show-logs (run &optional tail)
  "Display the logs of RUN in a dedicated buffer.
With TAIL non-nil, follow the run as it progresses."
  (spacelift--show-logs-buffer (spacelift-run-stack-id run) run tail))

;;;###autoload
(defun spacelift-stack-show-latest-logs (stack-id &optional tail)
  "Display the logs of the latest run of STACK-ID in a dedicated buffer.
With TAIL non-nil, follow the run as it progresses."
  (spacelift--show-logs-buffer stack-id nil tail))

(defun spacelift--show-logs-buffer (stack-id run tail)
  "Display a log buffer for STACK-ID and RUN, tailing when TAIL is non-nil.
When RUN is nil, stream the stack's latest run."
  (let ((buffer (get-buffer-create
                 (spacelift--run-log-buffer-name stack-id run))))
    (with-current-buffer buffer
      (spacelift-run-log-mode)
      (setq spacelift--log-stack-id stack-id
            spacelift--log-run run
            spacelift--log-tail tail)
      (spacelift--run-log-start stack-id run buffer tail))
    (pop-to-buffer buffer)))

(defun spacelift-run-logs (&optional tail)
  "View the logs of the run at point or in the current buffer.
With a prefix argument TAIL, follow the run as it progresses.
Works on the run under point in a run list buffer, the run shown in a
run detail buffer, or the run of the current log buffer."
  (interactive "P")
  (let ((run (or (spacelift--run-at-point-or-current)
                 (and (derived-mode-p 'spacelift-run-log-mode)
                      spacelift--log-run))))
    (unless run
      (user-error "No run at point or in the current buffer"))
    (spacelift-with-auth
      (spacelift-run-show-logs run tail))))

;;; Evil integration for run buffers

(defun spacelift--setup-run-evil-bindings ()
  "Bind the run-buffer keys in evil states, when evil is available."
  (when (fboundp 'evil-define-key*)
    (evil-define-key* '(motion normal) spacelift-run-list-mode-map
      (kbd "RET") #'spacelift-run-list-visit
      "w" #'spacelift-run-browse
      "l" #'spacelift-run-logs
      "r" #'spacelift-run-list-refresh
      "q" #'quit-window
      "?" #'spacelift-help)
    (evil-define-key* '(motion normal) spacelift-run-mode-map
      "w" #'spacelift-run-browse
      "l" #'spacelift-run-logs
      "r" #'spacelift-run-refresh
      "q" #'quit-window
      "?" #'spacelift-help)
    (evil-define-key* '(motion normal) spacelift-run-log-mode-map
      "w" #'spacelift-run-log-browse
      "r" #'spacelift-run-log-refresh
      "G" #'spacelift-run-log-tail
      "q" #'spacelift-run-log-quit
      "?" #'spacelift-help)
    (evil-define-key* '(motion normal) spacelift-stack-list-mode-map
      "R" #'spacelift-stack-list-runs
      "w" #'spacelift-stack-list-browse
      "l" #'spacelift-stack-list-latest-logs)
    (evil-define-key* '(motion normal) spacelift-stack-mode-map
      "R" #'spacelift-stack-runs
      "w" #'spacelift-stack-browse
      "l" #'spacelift-stack-latest-logs)))

(with-eval-after-load 'evil
  (spacelift--setup-run-evil-bindings))

(provide 'spacelift-ui)

;;; spacelift-ui.el ends here

;;; spacelift-core.el --- Core API layer for Spacelift -*- lexical-binding: t; -*-

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

;; Core layer for interacting with the Spacelift service through the
;; `spacectl' command-line tool.  This file defines the low-level
;; invocation helpers and JSON parsing used by the rest of the package.
;;
;; API functions are kept separate from display and interactive
;; functions, which live in `spacelift-stack.el'.

;;; Code:

(require 'json)

(defgroup spacelift nil
  "Interact with the Spacelift service from Emacs."
  :group 'tools
  :prefix "spacelift-")

(defcustom spacelift-spacectl-executable "spacectl"
  "Path to the `spacectl' executable used as backend."
  :type 'string
  :group 'spacelift)

(defcustom spacelift-profile nil
  "Spacelift profile alias to select before running commands.
When non-nil, `spacectl profile select' is used to make this the
current profile.  When nil, the profile already selected in
`spacectl' (or credentials from the environment) is used."
  :type '(choice (const :tag "Current profile" nil)
                 (string :tag "Profile alias"))
  :group 'spacelift)

(defcustom spacelift-login-offer t
  "When non-nil, offer to log in when `spacectl' is not authenticated."
  :type 'boolean
  :group 'spacelift)

(define-error 'spacelift-error "Spacelift error")
(define-error 'spacelift-not-authenticated
              "Not authenticated with Spacelift" 'spacelift-error)

(defconst spacelift--not-authenticated-regexp
  (rx (or "could not build the session"
          "no current profile is set"
          "please login first"
          (seq "not logged in")
          "could not find a valid session"))
  "Regexp matching `spacectl' output produced when not authenticated.")

(defun spacelift--command (args)
  "Build the full `spacectl' command argument list from ARGS.
Returns a list whose first element is the executable."
  (cons spacelift-spacectl-executable args))

(defun spacelift--run (&rest args)
  "Run `spacectl' synchronously with ARGS and return raw stdout as a string.
Signal `spacelift-not-authenticated' when the output indicates that no
valid credentials are available, or `spacelift-error' on other failures."
  (let* ((command (spacelift--command args))
         (stderr-file (make-temp-file "spacelift-stderr")))
    (unwind-protect
        (with-temp-buffer
          (let* ((status (apply #'call-process
                                (car command) nil
                                (list (current-buffer) stderr-file)
                                nil
                                (cdr command)))
                 (stdout (buffer-string))
                 (stderr (with-temp-buffer
                           (insert-file-contents stderr-file)
                           (string-trim (buffer-string)))))
            ;; `spacectl' may exit 0 yet still report a missing session on
            ;; stderr, so the authentication check inspects both streams.
            (when (string-match-p spacelift--not-authenticated-regexp
                                  (concat stdout "\n" stderr))
              (signal 'spacelift-not-authenticated (list stderr)))
            (unless (eq status 0)
              (signal 'spacelift-error
                      (list (format "%s exited with status %s: %s"
                                    spacelift-spacectl-executable
                                    status stderr))))
            stdout))
      (when (file-exists-p stderr-file)
        (delete-file stderr-file)))))

(defun spacelift--run-async (buffer name &rest args)
  "Run `spacectl' asynchronously with ARGS, streaming output into BUFFER.
NAME is used to label the process.  Output (both stdout and stderr) is
inserted into BUFFER as it arrives.  Returns the process object.  This is
intended for long-running or streamed commands such as run logs."
  (let* ((command (spacelift--command args))
         (process (make-process
                   :name name
                   :buffer buffer
                   :command command
                   :connection-type 'pipe
                   :noquery t)))
    process))

(defun spacelift--select-profile ()
  "Select `spacelift-profile' as the current `spacectl' profile, when set."
  (when spacelift-profile
    (spacelift--run "profile" "select" spacelift-profile)))

(defun spacelift--run-json (&rest args)
  "Run `spacectl' with ARGS plus `--output json' and parse the result.
Objects are parsed into alists, arrays into vectors, with keys as
symbols.  Signal a `spacelift-error' on failure to parse."
  (let ((output (apply #'spacelift--run (append args '("--output" "json")))))
    (condition-case err
        (let ((json-object-type 'alist)
              (json-array-type 'list)
              (json-key-type 'symbol)
              (json-false nil)
              (json-null nil))
          (json-read-from-string output))
      ;; Let authentication failures propagate so callers can offer login.
      (spacelift-not-authenticated (signal (car err) (cdr err)))
      (error
       (signal 'spacelift-error
               (list (format "Failed to parse JSON output: %s"
                             (error-message-string err))))))))

;;; Authentication and login

(defun spacelift-authenticated-p ()
  "Return non-nil when `spacectl' has valid Spacelift credentials."
  (condition-case nil
      (progn (spacelift--run "whoami") t)
    (spacelift-not-authenticated nil)
    (spacelift-error nil)))

(declare-function term-char-mode "term")

(defun spacelift--login-buffer-name (alias)
  "Return the login terminal buffer name for profile ALIAS."
  (format "*spacelift-login: %s*" alias))

;;;###autoload
(defun spacelift-profile-login (alias)
  "Log in to Spacelift by running `spacectl profile login' for ALIAS.
The interactive login flow (endpoint prompt, authentication method,
browser handoff) runs in a dedicated terminal buffer, since it
requires user input.  Returns the login buffer."
  (interactive
   (list (read-string "Spacelift profile alias: "
                      (or spacelift-profile ""))))
  (when (or (null alias) (string-empty-p alias))
    (user-error "A profile alias is required to log in"))
  (require 'term)
  (let* ((buffer-name (spacelift--login-buffer-name alias))
         (buffer (get-buffer buffer-name)))
    (when (and buffer (get-buffer-process buffer))
      (user-error "A login is already in progress in %s" buffer-name))
    ;; `make-term' wraps the name in earmuffs and starts the process in
    ;; `term-mode'; only character mode needs to be enabled for input.
    (setq buffer
          (make-term (string-remove-prefix
                      "*" (string-remove-suffix "*" buffer-name))
                     spacelift-spacectl-executable nil
                     "profile" "login" alias))
    (with-current-buffer buffer
      (term-char-mode))
    (pop-to-buffer buffer)
    (message "Complete the Spacelift login in %s, then retry." buffer-name)
    buffer))

(defun spacelift--maybe-offer-login (error-data)
  "Offer to log in after an authentication failure described by ERROR-DATA.
Signal `spacelift-not-authenticated' again when the user declines or
when `spacelift-login-offer' is nil."
  (if (and spacelift-login-offer
           (y-or-n-p "Not logged in to Spacelift.  Log in now? "))
      (call-interactively #'spacelift-profile-login)
    (signal 'spacelift-not-authenticated error-data)))

(defmacro spacelift-with-auth (&rest body)
  "Evaluate BODY, offering an interactive login on authentication failure.
When BODY signals `spacelift-not-authenticated' and
`spacelift-login-offer' is non-nil, the user is asked whether to log
in.  If they accept, a login terminal is opened; BODY is not retried
automatically, so the caller should be re-invoked after logging in."
  (declare (indent 0) (debug t))
  `(condition-case spacelift--err
       (progn
         (spacelift--select-profile)
         ,@body)
     (spacelift-not-authenticated
      (spacelift--maybe-offer-login (cdr spacelift--err)))))

;;; Account endpoint and console URLs

(defvar spacelift--endpoint nil
  "Cached Spacelift account endpoint URL, as reported by `spacectl whoami'.")

(defun spacelift-endpoint (&optional refresh)
  "Return the Spacelift account endpoint URL.
For example, \"https://acme.app.spacelift.io\".  The value is queried
once through `spacectl whoami' and cached.  With REFRESH non-nil, query
`spacectl' again and update the cache."
  (when (or refresh (null spacelift--endpoint))
    (let* ((data (let ((json-object-type 'alist)
                       (json-key-type 'symbol)
                       (json-false nil)
                       (json-null nil))
                   (json-read-from-string (spacelift--run "whoami"))))
           (endpoint (spacelift--alist-get 'endpoint data)))
      (unless endpoint
        (signal 'spacelift-error
                (list "Could not determine the Spacelift account endpoint")))
      (setq spacelift--endpoint (string-trim-right endpoint "/"))))
  spacelift--endpoint)

(defun spacelift-stack-url (stack-id)
  "Return the Spacelift console URL for the stack identified by STACK-ID."
  (format "%s/stack/%s" (spacelift-endpoint) stack-id))

(defun spacelift-run-url (stack-id run-id)
  "Return the Spacelift console URL for RUN-ID under stack STACK-ID."
  (format "%s/stack/%s/run/%s" (spacelift-endpoint) stack-id run-id))

;;; Generic helpers

(defun spacelift--alist-get (key object &optional default)
  "Return value for KEY in OBJECT alist, or DEFAULT when absent or nil."
  (or (alist-get key object) default))

(defun spacelift--format-unix-time (seconds)
  "Format SECONDS, a Unix timestamp, as a human-readable string.
Return an empty string when SECONDS is nil or zero."
  (if (and (numberp seconds) (> seconds 0))
      (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time seconds))
    ""))

(provide 'spacelift-core)

;;; spacelift-core.el ends here

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
(require 'seq)

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

(defcustom spacelift-login-method nil
  "Authentication method passed to `spacectl profile login' via `--method'.
When nil, `spacectl' prompts for the method interactively.  Set to one
of the supported method symbols to skip that prompt:

  `browser' - authenticate through a web browser;
  `api'     - authenticate with an API key and secret;
  `github'  - authenticate with a GitHub access token."
  :type '(choice (const :tag "Ask interactively" nil)
                 (const :tag "Web browser" browser)
                 (const :tag "API key" api)
                 (const :tag "GitHub access token" github))
  :group 'spacelift)

(defcustom spacelift-vcs-login nil
  "VCS login used to identify push-triggered runs as owned by you."
  :type '(choice (const :tag "Unset" nil) string)
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

(defun spacelift--run-graphql (query &optional variables)
  "Run the GraphQL QUERY through `spacectl api' and return its `data' alist.
VARIABLES, when non-nil, is an alist of GraphQL variables passed via
`--variables' as JSON.  `spacectl api' emits the raw response, so it is
parsed with the same settings as `spacelift--run-json'.  Signal a
`spacelift-error' when the response cannot be parsed or carries GraphQL
errors."
  (let* ((args (append (list "api" "--raw" query)
                       (when variables
                         (list "--variables" (json-encode variables)))))
         (output (apply #'spacelift--run args)))
    (condition-case err
        (let* ((json-object-type 'alist)
               (json-array-type 'list)
               (json-key-type 'symbol)
               (json-false nil)
               (json-null nil)
               (response (json-read-from-string output))
               (errors (alist-get 'errors response)))
          (when errors
            (signal 'spacelift-error
                    (list (format "GraphQL error: %s"
                                  (or (alist-get 'message (car errors))
                                      errors)))))
          (alist-get 'data response))
      (spacelift-not-authenticated (signal (car err) (cdr err)))
      (spacelift-error (signal (car err) (cdr err)))
      (error
       (signal 'spacelift-error
               (list (format "Failed to parse GraphQL output: %s"
                             (error-message-string err))))))))

;;; Authentication and login

(defun spacelift--token-payload ()
  "Return the decoded payload of the current session token as an alist.
The token is obtained through `spacectl profile export-token' and its
JWT payload segment is base64url-decoded and parsed as JSON.  Return nil
when no token is available or it cannot be decoded.

`spacectl profile current' and `profile export-token' only reflect the
stored profile, not whether its token is still valid, so the expiry must
be inspected from the payload itself."
  (let ((token (condition-case nil
                   (string-trim (spacelift--run "profile" "export-token"))
                 (spacelift-error nil))))
    (when (and token (not (string-empty-p token)))
      (let ((segments (split-string token "\\.")))
        (when (>= (length segments) 2)
          (condition-case nil
              (let* ((payload (nth 1 segments))
                     ;; JWT uses base64url without padding; translate to
                     ;; standard base64 and pad before decoding.
                     (b64 (replace-regexp-in-string
                           "_" "/" (replace-regexp-in-string "-" "+" payload)))
                     (padded (concat b64 (make-string
                                          (mod (- 4 (mod (length b64) 4)) 4)
                                          ?=)))
                     (json (decode-coding-string
                            (base64-decode-string padded) 'utf-8))
                     (json-object-type 'alist)
                     (json-key-type 'symbol)
                     (json-false nil)
                     (json-null nil))
                (json-read-from-string json))
            (error nil)))))))

(defun spacelift--session-valid-p ()
  "Return non-nil when the current session token exists and is unexpired.
Decodes the session token's `exp' claim and compares it to the current
time.  This is the reliable signal for whether `spacectl' can actually
authenticate, since the live API check (`whoami') and the stored profile
listing can disagree with the token's real validity."
  (let* ((payload (spacelift--token-payload))
         (exp (and payload (spacelift--alist-get 'exp payload))))
    (and (numberp exp)
         (> exp (float-time)))))

(defvar spacelift--current-user-login nil
  "Cached login of the authenticated Spacelift user.")

(defvar spacelift--current-user-name nil
  "Cached full name of the authenticated Spacelift user.")

(defun spacelift-current-user-login (&optional refresh)
  "Return the login of the authenticated user, or nil when unknown.
With REFRESH non-nil, re-read the current session token."
  (when (or refresh (null spacelift--current-user-login))
    (setq spacelift--current-user-login
          (spacelift--alist-get 'sub (spacelift--token-payload))))
  spacelift--current-user-login)

(defun spacelift-current-user-name (&optional refresh)
  "Return the full name of the authenticated user, or nil when unknown.
With REFRESH non-nil, re-read the current session token."
  (when (or refresh (null spacelift--current-user-name))
    (setq spacelift--current-user-name
          (spacelift--alist-get 'full_name (spacelift--token-payload))))
  spacelift--current-user-name)

(defun spacelift-authenticated-p ()
  "Return non-nil when `spacectl' has a valid, unexpired Spacelift session."
  (spacelift--session-valid-p))

(declare-function term-char-mode "term")

(defun spacelift--login-buffer-name (alias)
  "Return the login terminal buffer name for profile ALIAS."
  (format "*spacelift-login: %s*" alias))

(defun spacelift--profiles ()
  "Return the configured `spacectl' profiles as a list of alists.
Each entry contains at least `alias', `endpoint', `type' and `current'.
Return nil when the listing cannot be obtained or parsed."
  (condition-case nil
      (spacelift--run-json "profile" "list")
    (spacelift-error nil)))

(defun spacelift--profile-endpoint (alias)
  "Return the stored endpoint for profile ALIAS, or nil when unknown."
  (let ((entry (seq-find (lambda (p)
                           (equal (spacelift--alist-get 'alias p) alias))
                         (spacelift--profiles))))
    (spacelift--alist-get 'endpoint entry)))

(defun spacelift--current-profile-alias ()
  "Return the alias of the current `spacectl' profile, or nil when none."
  (spacelift--alist-get
   'alias (seq-find (lambda (p) (spacelift--alist-get 'current p))
                    (spacelift--profiles))))

(defun spacelift--default-login-alias ()
  "Return the best default alias to log in with.
Prefers `spacelift-profile', then the current `spacectl' profile."
  (or spacelift-profile (spacelift--current-profile-alias)))

(defun spacelift--login-sentinel (alias on-success orig-sentinel)
  "Build a process sentinel for the login terminal of profile ALIAS.
The returned sentinel first calls ORIG-SENTINEL (the terminal's own
sentinel), then, when `spacectl' exits successfully and a valid session
exists, kills the login buffer and calls ON-SUCCESS, if any, to resume
the originally requested operation."
  (lambda (process event)
    (when (functionp orig-sentinel)
      (funcall orig-sentinel process event))
    (when (memq (process-status process) '(exit signal))
      (let ((buffer (process-buffer process)))
        (if (and (eq (process-status process) 'exit)
                 (eq (process-exit-status process) 0)
                 (spacelift--session-valid-p))
            (progn
              (when (buffer-live-p buffer)
                (let ((window (get-buffer-window buffer t)))
                  (kill-buffer buffer)
                  (when (window-live-p window)
                    (ignore-errors (delete-window window)))))
              (message "Spacelift login for %s complete." alias)
              (when (functionp on-success)
                (funcall on-success)))
          (message "Spacelift login for %s did not complete." alias))))))

;;;###autoload
(defun spacelift-profile-login (alias &optional on-success force)
  "Log in to Spacelift by running `spacectl profile login' for ALIAS.
  When ALIAS already has a valid, unexpired session, no login is started
  and ON-SUCCESS, if any, is called immediately; the function returns nil.
  FORCE skips this existing-session check.
Otherwise the interactive login flow runs in a dedicated terminal
buffer.  The stored endpoint is reused via `--endpoint', and
`spacelift-login-method', when set, is passed via `--method' to skip the
method prompt.

When the login process exits successfully, the terminal buffer is killed
and ON-SUCCESS, a function of no arguments, is called to resume the
operation that triggered the login.  Returns the login buffer."
  (interactive
   (list (read-string "Spacelift profile alias: "
                      (or (spacelift--default-login-alias) ""))))
  (when (or (null alias) (string-empty-p alias))
    (user-error "A profile alias is required to log in"))
  ;; Recognise an existing, still-valid session and proceed without forcing
  ;; a fresh interactive login.
  (if (and (not force)
           (equal alias (spacelift--default-login-alias))
           (spacelift--session-valid-p))
      (progn
        (message "Spacelift session for %s is still valid; skipping login."
                 alias)
        (when (functionp on-success)
          (funcall on-success))
        nil)
    (require 'term)
    (let* ((buffer-name (spacelift--login-buffer-name alias))
           (buffer (get-buffer buffer-name))
           ;; Reuse the stored endpoint when the profile already exists so
           ;; `spacectl' does not prompt for it from scratch.
           (endpoint (spacelift--profile-endpoint alias))
           (args (append (list "profile" "login" alias)
                         (when endpoint (list "--endpoint" endpoint))
                         (when spacelift-login-method
                           (list "--method"
                                 (symbol-name spacelift-login-method))))))
      (when (and buffer (get-buffer-process buffer))
        (user-error "A login is already in progress in %s" buffer-name))
      ;; `make-term' wraps the name in earmuffs and starts the process in
      ;; `term-mode'; only character mode needs to be enabled for input.
      (setq buffer
            (apply #'make-term
                   (string-remove-prefix
                    "*" (string-remove-suffix "*" buffer-name))
                   spacelift-spacectl-executable nil
                   args))
      (with-current-buffer buffer
        (term-char-mode))
      ;; Chain onto the terminal's own sentinel so that a successful login
      ;; kills the buffer and resumes the requested operation.
      (let ((process (get-buffer-process buffer)))
        (set-process-sentinel
         process
         (spacelift--login-sentinel alias on-success
                                    (process-sentinel process))))
      (pop-to-buffer buffer)
      (message "Complete the Spacelift login in %s; it will resume on success."
               buffer-name)
      buffer)))

(defun spacelift--maybe-offer-login (error-data &optional on-success force)
  "Offer to log in after an authentication failure described by ERROR-DATA.
When the user accepts, start the login flow for the default profile and,
on success, call ON-SUCCESS to resume the requested operation.  Signal
`spacelift-not-authenticated' again when the user declines or when
`spacelift-login-offer' is nil."
  (if (and spacelift-login-offer
           (y-or-n-p "Not logged in to Spacelift.  Log in now? "))
      (spacelift-profile-login
       (or (spacelift--default-login-alias)
           (read-string "Spacelift profile alias: "))
       on-success
       force)
    (signal 'spacelift-not-authenticated error-data)))

(defun spacelift--call-with-auth (thunk &optional retrying)
  "Call THUNK, offering an interactive login on authentication failure.
When THUNK signals `spacelift-not-authenticated' and
`spacelift-login-offer' is non-nil, the user is asked whether to log in.
If they accept, a login terminal is opened and THUNK is re-run once the
login succeeds, resuming the originally requested operation."
  (condition-case spacelift--err
      (progn
        (spacelift--select-profile)
        (funcall thunk))
    (spacelift-not-authenticated
     (if retrying
         (signal (car spacelift--err) (cdr spacelift--err))
       (spacelift--maybe-offer-login
        (cdr spacelift--err)
        (lambda () (spacelift--call-with-auth thunk t))
        t)))))

(defmacro spacelift-with-auth (&rest body)
  "Evaluate BODY, offering an interactive login on authentication failure.
When BODY signals `spacelift-not-authenticated' and
`spacelift-login-offer' is non-nil, the user is asked whether to log in.
If they accept, a login terminal is opened; once the login succeeds the
terminal is killed and BODY is re-run to resume the requested
operation."
  (declare (indent 0) (debug t))
  `(spacelift--call-with-auth (lambda () ,@body)))

;;; Account endpoint and console URLs

(defvar spacelift--endpoint nil
  "Cached Spacelift account endpoint URL, from `spacectl profile list'.")

(defun spacelift-endpoint (&optional refresh)
  "Return the Spacelift account endpoint URL.
For example, \"https://acme.app.spacelift.io\".  The endpoint is read
from the current profile reported by `spacectl profile list' and cached.
With REFRESH non-nil, query `spacectl' again and update the cache."
  (when (or refresh (null spacelift--endpoint))
    (let* ((current (seq-find (lambda (p)
                                (spacelift--alist-get 'current p))
                              (spacelift--profiles)))
           (endpoint (spacelift--alist-get 'endpoint current)))
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

(defun spacelift-worker-pool-url (pool-id)
  "Return the Spacelift console URL for the worker pool identified by POOL-ID."
  (format "%s/worker-pool/%s" (spacelift-endpoint) pool-id))

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

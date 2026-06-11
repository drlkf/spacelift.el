;;; spacelift-core.el --- Core API layer for Spacelift -*- lexical-binding: t; -*-

;; Author: drlkf
;; Keywords: tools, processes
;; Package-Requires: ((emacs "27.1"))

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
  "Spacelift profile to use, passed as `--profile'.
When nil, the default profile configured in `spacectl' is used."
  :type '(choice (const :tag "Default" nil)
                 (string :tag "Profile name"))
  :group 'spacelift)

(define-error 'spacelift-error "Spacelift error")

(defun spacelift--command (args)
  "Build the full `spacectl' command argument list from ARGS.
Returns a list whose first element is the executable."
  (append (list spacelift-spacectl-executable)
          (when spacelift-profile
            (list "--profile" spacelift-profile))
          args))

(defun spacelift--run (&rest args)
  "Run `spacectl' synchronously with ARGS and return raw stdout as a string.
Signal a `spacelift-error' if the process exits non-zero."
  (let* ((command (spacelift--command args))
         (stderr-file (make-temp-file "spacelift-stderr")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process
                               (car command) nil
                               (list (current-buffer) stderr-file)
                               nil
                               (cdr command))))
            (unless (eq status 0)
              (signal 'spacelift-error
                      (list (format "%s exited with status %s: %s"
                                    spacelift-spacectl-executable
                                    status
                                    (with-temp-buffer
                                      (insert-file-contents stderr-file)
                                      (string-trim (buffer-string)))))))
            (buffer-string)))
      (when (file-exists-p stderr-file)
        (delete-file stderr-file)))))

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
      (error
       (signal 'spacelift-error
               (list (format "Failed to parse JSON output: %s"
                             (error-message-string err))))))))

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

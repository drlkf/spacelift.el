;;; spacelift.el --- Interact with Spacelift from Emacs -*- lexical-binding: t; -*-

;; Author: drlkf
;; Version: 0.1.0
;; Keywords: tools, processes
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/drlkf/drlkf-spacelift.el

;;; Commentary:

;; spacelift.el integrates the Spacelift service into Emacs, using the
;; `spacectl' command-line tool as backend.
;;
;; Entry points:
;;
;; - `spacelift-stack-list-stacks' opens a buffer listing your stacks.
;; - `spacelift-stack-show-buffer' opens a buffer with a stack's details.
;;
;; See the README for setup instructions.

;;; Code:

(require 'spacelift-core)
(require 'spacelift-stack)
(require 'spacelift-ui)

(provide 'spacelift)

;;; spacelift.el ends here

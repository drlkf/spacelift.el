;;; spacelift.el --- Interact with the Spacelift service -*- lexical-binding: t; -*-

;; Copyright (C) 2026 drlkf

;; Author: drlkf <drlkf@drlkf.net>
;; Assisted-by: Claude:claude-opus-4-8
;; Version: 0.1.0
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

;; spacelift.el integrates the Spacelift service into Emacs, using the
;; `spacectl' command-line tool as backend.
;;
;; Entry points:
;;
;; - `spacelift-stack-list-stacks' opens a buffer listing your stacks.
;; - `spacelift-stack-show-buffer' opens a buffer with a stack's details.
;; - `spacelift-run-list-buffer' opens a buffer listing a stack's runs.
;;
;; See the README for setup instructions.

;;; Code:

(require 'spacelift-core)
(require 'spacelift-stack)
(require 'spacelift-run)
(require 'spacelift-ui)

(provide 'spacelift)

;;; spacelift.el ends here

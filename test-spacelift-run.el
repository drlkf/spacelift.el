(require 'ert)
(require 'spacelift-run)
(require 'spacelift-ui)

(ert-deftest spacelift-auth-offers-login-only-once-after-failure ()
  (let ((offers 0)
        (failure (list "still unauthenticated")))
    (cl-letf (((symbol-function 'spacelift--select-profile) #'ignore)
              ((symbol-function 'spacelift--maybe-offer-login)
               (lambda (&rest _)
                 (setq offers (1+ offers))
                 (signal 'spacelift-not-authenticated failure))))
      (should-error (spacelift--call-with-auth
                     (lambda ()
                       (signal 'spacelift-not-authenticated failure)))
                    :type 'spacelift-not-authenticated)
      (should (= offers 1)))))

(ert-deftest spacelift-run-prioritize-uses-the-requested-action ()
  (let ((run (spacelift-run-create :id "run-1" :stack-id "stack-1"))
        command)
    (cl-letf (((symbol-function 'spacelift--run)
               (lambda (&rest args) (setq command args))))
      (spacelift-run-prioritize run)
      (should (equal command '("stack" "prioritize" "--id" "stack-1"
                               "--run" "run-1")))
      (spacelift-run-prioritize run t)
      (should (equal command '("stack" "deprioritize" "--id" "stack-1"
                               "--run" "run-1"))))))

(ert-deftest spacelift-run-discard-uses-the-requested-action ()
  (let ((run (spacelift-run-create :id "run-1" :stack-id "stack-1"))
        command)
    (cl-letf (((symbol-function 'spacelift--run)
               (lambda (&rest args) (setq command args))))
      (spacelift-run-discard run)
      (should (equal command '("stack" "discard" "--id" "stack-1"
                               "--run" "run-1"))))))

(ert-deftest spacelift-run-log-retry-retries-the-buffer-run ()
  (let ((run (spacelift-run-create :id "run-1" :stack-id "stack-1"))
        retried)
    (with-temp-buffer
      (spacelift-run-log-mode)
      (setq spacelift--log-stack-id "stack-1"
            spacelift--log-run run)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'spacelift-run-retry)
                 (lambda (value) (setq retried value))))
        (spacelift-run-log-retry)
        (should (eq retried run))))))

(ert-deftest spacelift-run-log-targets-its-run-for-prioritization ()
  (let ((run (spacelift-run-create :id "run-1" :stack-id "stack-1")))
    (with-temp-buffer
      (spacelift-run-log-mode)
      (setq spacelift--log-stack-id "stack-1"
            spacelift--log-run run)
      (should (eq (spacelift--run-at-point-or-current) run))
      (should (eq (lookup-key spacelift-run-log-mode-map (kbd "P"))
                  #'spacelift-run-prioritize-at-point)))))

(ert-deftest spacelift-discard-is-bound-to-d-in-action-buffers ()
  (dolist (entry `((,spacelift-stack-list-mode-map . spacelift-stack-list-discard)
                   (,spacelift-stack-mode-map . spacelift-stack-discard)
                   (,spacelift-run-list-mode-map . spacelift-run-discard-at-point)
                   (,spacelift-run-mode-map . spacelift-run-discard-at-point)
                   (,spacelift-run-log-mode-map . spacelift-run-discard-at-point)))
    (should (eq (lookup-key (car entry) (kbd "d"))
                (cdr entry)))))

(ert-deftest spacelift-prioritize-is-bound-to-p-in-stack-buffers ()
  (dolist (map (list spacelift-stack-list-mode-map
                     spacelift-stack-mode-map))
    (should (eq (lookup-key map (kbd "P"))
                (if (eq map spacelift-stack-list-mode-map)
                    #'spacelift-stack-list-prioritize
                  #'spacelift-stack-prioritize)))))

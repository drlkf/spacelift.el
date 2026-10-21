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

(ert-deftest spacelift-owned-unconfirmed-run-uses-dedicated-face ()
  (let ((run (spacelift-run-create :state "UNCONFIRMED"
                                   :triggered-by "user@example.com")))
    (cl-letf (((symbol-function 'spacelift-current-user-login)
               (lambda (&optional _) "user@example.com")))
      (should (eq (get-text-property 0 'face
                                     (spacelift--propertize-run-state run))
                  'spacelift-state-unconfirmed-owned-face)))))

(ert-deftest spacelift-vcs-owned-unconfirmed-run-uses-dedicated-face ()
  (let ((run (spacelift-run-create
              :state "UNCONFIRMED"
              :triggered-by "vcs/commit"
              :commit (spacelift-commit-create :login "vcs-user"))))
    (let ((spacelift-vcs-login "vcs-user"))
      (should (spacelift-run-owned-p run)))))

(ert-deftest spacelift-name-owned-unconfirmed-run-uses-dedicated-face ()
  (let ((run (spacelift-run-create
              :state "UNCONFIRMED"
              :triggered-by "vcs/commit"
              :commit (spacelift-commit-create :author "User NAME"))))
    (cl-letf (((symbol-function 'spacelift-current-user-name)
               (lambda (&optional _) "User Name")))
      (should (spacelift-run-owned-p run)))))

(ert-deftest spacelift-stack-list-next-owned-unconfirmed-wraps ()
  (let ((owned (spacelift-stack-create
                :id "owned" :blocker-id "run-1" :blocker-state "UNCONFIRMED"
                :blocker-commit (spacelift-commit-create :login "me")))
        (other (spacelift-stack-create
                :id "other" :blocker-id "run-2" :blocker-state "UNCONFIRMED"
                :blocker-commit (spacelift-commit-create :login "someone-else"))))
    (with-temp-buffer
      (let ((spacelift-vcs-login "me"))
        (spacelift-stack-list-mode)
        (let ((inhibit-read-only t))
          (insert (propertize "owned\n" 'spacelift-stack owned)
                  (propertize "other\n" 'spacelift-stack other)))
        (goto-char (point-max))
        (spacelift-stack-list-next-owned-unconfirmed)
        (should (eq (spacelift-stack-list-stack-at-point) owned))))))

(ert-deftest spacelift-stack-line-owned-unconfirmed-run-uses-dedicated-face ()
  (let ((stack (spacelift-stack-create
                :id "stack-1"
                :state "UNCONFIRMED"
                :blocker-id "run-1"
                :blocker-state "UNCONFIRMED"
                :blocker-commit (spacelift-commit-create
                                 :author "User Name"))))
    (cl-letf (((symbol-function 'spacelift-current-user-name)
               (lambda (&optional _) "User Name")))
      (let ((line (spacelift--stack-line stack)))
        (should (eq (get-text-property (string-match "UNCONFIRMED" line)
                                       'face line)
                    'spacelift-state-unconfirmed-owned-face))))))

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

(ert-deftest spacelift-run-log-no-confirm-keys-are-bound ()
  (should (eq (lookup-key spacelift-run-log-mode-map (kbd "C"))
              #'spacelift-run-confirm-at-point-no-confirm))
  (should (eq (lookup-key spacelift-run-log-mode-map (kbd "T"))
              #'spacelift-run-log-retry-no-confirm)))

(ert-deftest spacelift-run-log-retry-no-confirm-skips-prompt ()
  (let ((run (spacelift-run-create :id "run-1" :stack-id "stack-1"))
        prompted retried)
    (with-temp-buffer
      (spacelift-run-log-mode)
      (setq spacelift--log-stack-id "stack-1"
            spacelift--log-run run)
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (setq prompted t)))
                ((symbol-function 'spacelift-run-retry)
                 (lambda (value) (setq retried value))))
        (spacelift-run-log-retry-no-confirm)
        (should-not prompted)
        (should (eq retried run))))))

(ert-deftest spacelift-stack-list-uppercase-t-retries-without-confirmation ()
  (let (argument)
    (cl-letf (((symbol-function 'spacelift-stack-list-stack-at-point)
               (lambda () 'stack))
              ((symbol-function 'spacelift--retry-stack-current-run)
               (lambda (_ no-confirm)
                 (setq argument no-confirm)
                 nil)))
      (spacelift-stack-list-retry-no-confirm)
      (should argument))))

(ert-deftest spacelift-stack-list-uppercase-c-confirms-without-confirmation ()
  (let (argument)
    (cl-letf (((symbol-function 'spacelift-stack-list-stack-at-point)
               (lambda () 'stack))
              ((symbol-function 'spacelift--confirm-stack-current-run)
               (lambda (_ no-confirm)
                 (setq argument no-confirm)
                 nil)))
      (spacelift-stack-list-confirm-no-confirm)
      (should argument))))

(ert-deftest spacelift-no-prompt-variables-skip-prompts ()
  (let ((run (spacelift-run-create :id "run-1" :stack-id "stack-1"
                                   :state "UNCONFIRMED"))
        (spacelift-confirm-no-prompt t)
        (spacelift-discard-no-prompt t)
        (spacelift-prioritize-no-prompt t)
        prompted called)
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (setq prompted t)))
              ((symbol-function 'spacelift--select-profile) #'ignore)
              ((symbol-function 'spacelift--run-at-point-or-current)
               (lambda () run))
              ((symbol-function 'spacelift-run-confirm)
               (lambda (&rest _) (push 'confirm called)))
              ((symbol-function 'spacelift-run-discard)
               (lambda (&rest _) (push 'discard called)))
              ((symbol-function 'spacelift-run-prioritize)
               (lambda (&rest _) (push 'prioritize called))))
      (spacelift-run-confirm-at-point)
      (spacelift-run-discard-at-point)
      (spacelift-run-prioritize-at-point)
      (should-not prompted)
      (should (equal called '(prioritize discard confirm))))))

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

(ert-deftest spacelift-run-parse-plan-diff-keeps-only-real-changes ()
  (let* ((log (concat
               "~ pulumi:pulumi:Stack: (refresh)\n"
               "    [urn=urn:pulumi:test::proj::pulumi:pulumi:Stack::test]\n"
               "  pulumi:pulumi:Stack: (same)\n"
               "    [urn=urn:pulumi:test::proj::pulumi:pulumi:Stack::test]\n"
               "\n"
               "@ previewing update....\n"
               "    > pulumi:pulumi:StackReference: (read)\n"
               "        [id=organization/central/prod-eu1]\n"
               "        [urn=urn:pulumi:test::proj::pulumi:pulumi:StackReference::organization/central/prod-eu1]\n"
               "        name: \"organization/central/prod-eu1\"\n"
               "    ~ gcp:compute/firewall:Firewall: (update)\n"
               "        [id=projects/test/global/firewalls/allow-gcp-health-checks]\n"
               "        [urn=urn:pulumi:test::proj::gcp:compute/firewall:Firewall::allow-gcp-health-checks]\n"
               "        [provider=urn:pulumi:test::proj::pulumi:providers:gcp::test-gcp-provider::abc123]\n"
               "      ~ allows: [\n"
               "          ~ [0]: {\n"
               "                  ~ ports: [\n"
               "                      ~ [0]: \"8001\" => \"8002\"\n"
               "                    ]\n"
               "                }\n"
               "        ]\n"
               "    +-kubernetes:networking.gke.io/v1:HealthCheckPolicy: (replace)\n"
               "        [id=tsuga/tsuga-cluster-intake-healthcheck]\n"
               "        [urn=urn:pulumi:test::proj::kubernetes:networking.gke.io/v1:HealthCheckPolicy::test-intake-healthcheck]\n"
               "        [provider=urn:pulumi:test::proj::pulumi:providers:kubernetes::test-k8s-provider::def456]\n"
               "      ~ metadata: {\n"
               "          ~ name: \"a\" => \"b\"\n"
               "        }\n"
               "\n"
               "Resources:\n"
               "    ~ 4 to update\n"
               "    +-1 to replace\n"
               "    5 changes. 423 unchanged\n"
               "\n"
               "Policy Packs run:\n"))
         (result (spacelift-run--parse-plan-diff log))
         (texts (mapcar #'cdr result)))
    (should (cl-every (lambda (e) (eq (car e) 'diff)) (butlast result 4)))
    (should (cl-every (lambda (e) (eq (car e) 'summary)) (last result 4)))
    (should-not (cl-some (lambda (l) (string-match-p "(refresh)\\|(same)\\|(read)" l))
                         texts))
    (should-not (cl-some (lambda (l) (string-match-p "\\[urn=\\|\\[provider=" l))
                         texts))
    (should (cl-some (lambda (l) (string-match-p "\\[id=" l)) texts))
    (should (cl-some (lambda (l) (string-match-p "gcp:compute/firewall:Firewall: (update)" l))
                     texts))
    (should (cl-some (lambda (l) (string-match-p "HealthCheckPolicy: (replace)" l))
                     texts))
    (should (cl-some (lambda (l) (string-match-p "^Resources:$" l)) texts))
    (should (cl-some (lambda (l) (string-match-p "to update" l)) texts))))

(ert-deftest spacelift-run-parse-plan-diff-collects-apply-errors ()
  (let* ((log (concat
               "    ~ azure-native:containerservice:ManagedCluster: (update) \xf0\x9f\x94\x92\n"
               "        [id=/subscriptions/.../managedClusters/test]\n"
               "        [urn=urn:pulumi:test::proj::azure-native:containerservice:ManagedCluster::aks]\n"
               "        [provider=urn:pulumi:test::proj::pulumi:providers:azure-native::azure-provider::abc]\n"
               "      ~ agentPoolProfiles: [\n"
               "          ~ [0]: {\n"
               "                  ~ count: 2 => 1\n"
               "                }\n"
               "        ]\n"
               "error: Status=409 Code=\"OperationNotAllowed\" Message=\"{\n"
               "  \"code\": \"OperationNotAllowed\",\n"
               "  \"subcode\": \"AnotherOperationInProgress\"\n"
               " }\"\n"
               "error: update failed\n"
               "Resources:\n"
               "    194 unchanged\n"
               "    <{%fg 1%}>1 errored<{%reset%}>\n"
               "\n"
               "Policy Packs run:\n"))
         (result (spacelift-run--parse-plan-diff log))
         (texts (mapcar #'cdr result))
         (errors (seq-filter (lambda (e) (eq (car e) 'error)) result)))
    (should (cl-some (lambda (l) (string-match-p "ManagedCluster: (update)" l)) texts))
    (should-not (cl-some (lambda (l) (string-match-p "\\[urn=\\|\\[provider=" l)) texts))
    (should (= (cl-count-if (lambda (e) (string-match-p "^error:" (cdr e))) errors) 2))
    (should (cl-some (lambda (e) (string-match-p "OperationNotAllowed" (cdr e))) errors))
    (should (cl-some (lambda (e) (string-match-p "AnotherOperationInProgress" (cdr e))) errors))
    (should (cl-some (lambda (e) (string-match-p "update failed" (cdr e))) errors))
    (should (cl-some (lambda (l) (string-match-p "^ *1 errored$" l)) texts))
    (should-not (cl-some (lambda (l) (string-match-p "<{%" l)) texts))))

(ert-deftest spacelift-run-plan-diff-falls-back-to-last-lines-on-failure ()
  (clrhash spacelift-run--plan-diff-cache)
  (let ((run (spacelift-run-create :id "run-1" :stack-id "stack-1" :state "FAILED")))
    (cl-letf (((symbol-function 'spacelift-run-failed-phase)
               (lambda (_run) "APPLYING"))
              ((symbol-function 'spacelift-run-plan-log)
               (lambda (_run _phase) "line one\nline two\n\nline three\n")))
      (let ((result (spacelift-run-plan-diff run)))
        (should (equal (car result) '(error . "Failed during APPLYING")))
        (should (equal (mapcar #'cdr (cdr result))
                       '("line one" "line two" "line three")))))))

(ert-deftest spacelift-stack-list-toggle-diff-shows-and-hides-lines ()
  (let ((stack (spacelift-stack-create :id "stack-1" :name "stack-1"))
        (run (spacelift-run-create :id "run-1" :stack-id "stack-1")))
    (with-temp-buffer
      (spacelift-stack-list-mode)
      (spacelift--insert-stack-list (list stack))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'spacelift--select-profile) #'ignore)
                ((symbol-function 'spacelift-stack-current-run)
                 (lambda (_stack) run))
                ((symbol-function 'spacelift-run-plan-diff)
                 (lambda (_run) (list (cons 'diff "~ some:Resource: (update)")))))
        (should (= (count-lines (point-min) (point-max)) 1))
        (spacelift-stack-list-toggle-diff)
        (should (= (count-lines (point-min) (point-max)) 2))
        (goto-char (point-min))
        (forward-line 1)
        (should (equal (buffer-substring (line-beginning-position) (line-end-position))
                       "    ~ some:Resource: (update)"))
        (goto-char (point-min))
        (spacelift-stack-list-toggle-diff)
        (should (= (count-lines (point-min) (point-max)) 1))))))

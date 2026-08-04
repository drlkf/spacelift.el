(require 'ert)
(require 'spacelift-run)

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

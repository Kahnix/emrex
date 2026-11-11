;;; emrex-test.el --- Tests for emrex -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with: emacs -Q --batch -L . -l emrex-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'emrex)

(defun emrex-test--with-pane (fn)
  "Call FN with the selected frame pretending to be a Rex pane."
  (let ((client (frame-parameter nil 'client))
        (environment (frame-parameter nil 'environment))
        (emrex-mode t))
    (unwind-protect
        (progn
          (set-frame-parameter nil 'client 'fake)
          (set-frame-parameter nil 'environment '("REX_BLOCK=block:1"))
          (funcall fn))
      (set-frame-parameter nil 'client client)
      (set-frame-parameter nil 'environment environment))))

(ert-deftest emrex-test-new-lines ()
  "SIZE is the lines the selected window keeps, as in `split-window-below'."
  (should (equal 14 (emrex--new-lines 10 24)))
  (should (equal 5 (emrex--new-lines -5 24)))
  (should (equal 20 (emrex--new-lines '(4) 24)))
  (should (null (emrex--new-lines nil 24))))

(ert-deftest emrex-test-ratio ()
  "The new pane gets the rest of the window, within the 5-95 percent clamp."
  (let ((window (selected-window))
        (width (window-total-width)))
    (should (= 50 (emrex--ratio window "right" (/ width 2))))
    (should (= 5 (emrex--ratio window "right" 0)))
    (should (= 95 (emrex--ratio window "right" width)))
    (should (= 5 (emrex--ratio window "right" -100)))))

(ert-deftest emrex-test-after-resize ()
  "The pane waits for Rex's resize before starting emacsclient."
  (let ((emrex-resize-wait nil))
    (should (null (emrex--after-resize))))
  (let* ((emrex-resize-wait 1.5)
         (command (emrex--after-resize)))
    (should (equal "/bin/sh" (car command)))
    (should (equal "-c" (cadr command)))
    (should (string-match-p "trap 'exec \"\\$0\" \"\\$@\"' WINCH" (caddr command)))
    (should (string-match-p "sleep 1\\.5" (caddr command)))))

(ert-deftest emrex-test-server-args ()
  "Panes connect to this Emacs's own server socket."
  (let ((server-use-tcp nil)
        (server-name "server")
        (server-socket-dir "/tmp/socket"))
    (should (equal '("-s" "/tmp/socket/server") (emrex--server-args)))))

(ert-deftest emrex-test-base-action ()
  "Turning the mode on adds the action once, and off removes it again."
  (let ((display-buffer-base-action '(nil)))
    (should (equal '((emrex-display-buffer)) (emrex--base-action t)))
    (setq display-buffer-base-action (emrex--base-action t))
    (should (equal '(nil) (emrex--base-action nil)))))

(ert-deftest emrex-test-quit-refuses-unsaved ()
  "`evil-quit' must not close a pane whose buffer has unsaved changes."
  (emrex-test--with-pane
   (lambda ()
     (let (deleted)
       (cl-letf (((symbol-function 'delete-frame)
                  (lambda (&rest _) (setq deleted t))))
         (with-temp-buffer
           (insert "unsaved")
           (set-window-buffer (selected-window) (current-buffer))
           (should-error (emrex--evil-quit-a #'ignore) :type 'user-error))
         (should-not deleted))))))

(ert-deftest emrex-test-quit-closes-clean-pane ()
  "A clean buffer in a pane's only window closes the pane."
  (emrex-test--with-pane
   (lambda ()
     (let (deleted)
       (cl-letf (((symbol-function 'delete-frame)
                  (lambda (&rest _) (setq deleted t))))
         (with-temp-buffer
           (set-window-buffer (selected-window) (current-buffer))
           (emrex--evil-quit-a #'ignore))
         (should deleted))))))

(provide 'emrex-test)
;;; emrex-test.el ends here

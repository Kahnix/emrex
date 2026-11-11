;;; emrex.el --- Emacs windows as Rex panes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kacper Daniel

;; Author: Kacper Daniel <kacperdev@gmail.com>
;; URL: https://github.com/Kahnix/emrex
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: frames, terminals, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; emrex turns Emacs windows into real panes of Rex, the terminal
;; multiplexer (https://www.superlogical.com/rex), the way neorex does for
;; Neovim.
;;
;; One Emacs server runs behind every pane, so buffers, registers, undo, the
;; kill ring and language servers are shared.  Each pane runs `emacsclient
;; -t': one terminal frame holding one window.
;;
;; - Splitting (C-x 2, C-x 3, C-w s, C-w v, :split, :vsplit) opens a Rex
;;   pane beside this one, showing the same buffer at the same point.
;; - Deleting the window (C-x 0, C-w c, :close, :q) closes its pane, and
;;   closing the pane in Rex deletes the window.
;; - C-x 1 and :only close the other Emacs panes in the Rex window.
;; - C-x o and C-w w, W, h, j, k, l move between panes through Rex, once
;;   they run out of windows inside this pane.
;; - `display-buffer' shows a buffer in another Emacs pane of the Rex window
;;   where Emacs would use another window (C-x 4 b, xref, compilation
;;   errors, ...): a pane already showing it, or else the least recently
;;   used one.  It doesn't open panes: it must return a window at once, and
;;   a new pane takes a moment to start.  With no other pane, Emacs splits
;;   inside this one as usual.
;; - When a command selects a window in another pane, Rex focuses that pane.
;; - With persp-mode (Doom's workspaces), a new pane joins the workspace of
;;   the pane it was split from instead of getting a workspace of its own.
;;
;; Side windows, such as Doom's popups, which-key, transient and completion,
;; stay inside their pane.  Frames outside Rex (GUI frames, other terminals,
;; a plain `emacs -nw') keep Emacs's own window commands.
;;
;; Usage: run the Emacs server, turn on `emrex-mode', and run `emacsclient
;; -t' in a Rex pane.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'server)
(require 'subr-x)

(defvar emrex-mode)
(defvar evil-split-window-below)
(defvar evil-vsplit-window-right)
(declare-function evil-ex-define-cmd "ext:evil-ex" (cmd function))
(declare-function get-frame-persp "ext:persp-mode" (&optional frame))
(declare-function safe-persp-name "ext:persp-mode" (p))
(declare-function persp-frame-switch "ext:persp-mode" (name &optional frame))
(declare-function persp-frames-with-persp "ext:persp-mode" (&optional persp))
(declare-function persp-kill "ext:persp-mode"
                  (names &optional dont-kill-buffers called-interactively-p))
(declare-function +workspace/close-window-or-workspace "ext:workspaces" ())

(defgroup emrex nil
  "Emacs windows as Rex panes."
  :group 'frames
  :prefix "emrex-")

(defcustom emrex-rex-program nil
  "The Rex command-line program.
nil means the `rex' in the pane's REX_BIN_DIR, then `rex' on variable
`exec-path'."
  :type '(choice (const :tag "The pane's" nil) file))

(defcustom emrex-emacsclient-program nil
  "The emacsclient a new pane runs.
nil means the one installed beside this Emacs, then `emacsclient' on
variable `exec-path'."
  :type '(choice (const :tag "Beside this Emacs" nil) file))

(defcustom emrex-resize-wait 1.0
  "Seconds a new pane waits for Rex to size it before starting emacsclient.
Rex starts a pane's terminal at 80x24 and resizes it a moment later;
starting emacsclient after that keeps the new frame from drawing at the
wrong size and then reflowing.  The pane starts as soon as the resize
arrives, or after this many seconds when none does.  nil starts at once."
  :type '(choice (const :tag "Start at once" nil) number))

;;;; Panes

(defun emrex--block (&optional frame)
  "The Rex block FRAME's emacsclient runs in, or nil.
FRAME defaults to the selected frame.  Only terminal frames that
emacsclient made inside a Rex pane have one."
  (let ((frame (or frame (selected-frame))))
    (and (frame-live-p frame)
         (eq (framep frame) t)
         (frame-parameter frame 'client)
         (getenv "REX_BLOCK" frame))))

(defun emrex--pane-p ()
  "Non-nil if `emrex-mode' manages the selected frame."
  (and emrex-mode (emrex--block)))

(defun emrex--sole-window-p ()
  "Non-nil if the selected window is the only window of a managed pane."
  (and (emrex--pane-p) (frame-root-window-p (selected-window))))

;;;; Running rex

(defun emrex--environment (frame)
  "`process-environment' with FRAME's REX_ variables, for rex to find its pane."
  (append (seq-filter (lambda (var) (string-prefix-p "REX_" var))
                      (frame-parameter frame 'environment))
          process-environment))

(defun emrex--local-directory ()
  "`default-directory' if processes can start there, else the home directory."
  (if (and (not (file-remote-p default-directory))
           (file-directory-p default-directory))
      default-directory
    (expand-file-name "~/")))

(defun emrex--rex-program (frame)
  "The rex program for FRAME's pane."
  (or emrex-rex-program
      (when-let* ((dir (getenv "REX_BIN_DIR" frame))
                  (rex (expand-file-name "rex" dir))
                  ((file-executable-p rex)))
        rex)
      (executable-find "rex")
      (user-error "emrex: can't find rex; set `emrex-rex-program'")))

(defun emrex--rex (frame &rest args)
  "Run rex with ARGS for FRAME's pane and return what it prints.
Signal an error if it fails."
  (let ((process-environment (emrex--environment frame))
        (default-directory (emrex--local-directory))
        (errors (make-temp-file "emrex")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process (emrex--rex-program frame)
                               nil (list t errors) nil args)))
            (unless (eql status 0)
              (error "emrex: rex %s: %s" (string-join args " ")
                     (with-temp-buffer
                       (insert-file-contents errors)
                       (string-trim (buffer-string)))))
            (buffer-string)))
      (delete-file errors))))

(defun emrex--rex-async (frame on-failure &rest args)
  "Start rex with ARGS for FRAME's pane, without waiting for it.
If it fails, report why and call ON-FAILURE, unless that is nil."
  (let ((process-environment (emrex--environment frame))
        (default-directory (emrex--local-directory))
        (output (generate-new-buffer " *emrex-rex*" t)))
    (make-process
     :name "emrex-rex"
     :buffer output
     :command (cons (emrex--rex-program frame) args)
     :connection-type 'pipe
     :noquery t
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (unwind-protect
             (unless (zerop (process-exit-status process))
               (when on-failure (funcall on-failure))
               (message "emrex: rex %s: %s" (string-join args " ")
                        (with-current-buffer output
                          (string-trim (buffer-string)))))
           (kill-buffer output)))))))

(defun emrex--focus (frame target &rest args)
  "Ask Rex to focus TARGET (a block, or a direction with ARGS) from FRAME."
  (apply #'emrex--rex-async frame nil "focus" target args))

;;;; Opening panes

(cl-defstruct (emrex--spawn (:constructor emrex--spawn-create) (:copier nil))
  "A pane whose emacsclient hasn't connected yet."
  origin buffer point start file read-only)

(defvar emrex--spawns (make-hash-table)
  "Spawns waiting for their emacsclient, by number.")

(defvar emrex--spawn-count 0
  "The number of the last spawn.")

(defun emrex--emacsclient ()
  "The emacsclient program new panes run."
  (or emrex-emacsclient-program
      (let ((beside (expand-file-name "emacsclient" invocation-directory)))
        (and (file-executable-p beside) beside))
      (executable-find "emacsclient")
      (user-error "emrex: can't find emacsclient; set `emrex-emacsclient-program'")))

(defun emrex--server-args ()
  "Arguments for emacsclient that connect to this Emacs's server."
  (if server-use-tcp
      (list "-f" (expand-file-name server-name server-auth-dir))
    (list "-s" (expand-file-name server-name server-socket-dir))))

(defun emrex--after-resize ()
  "Command prefix that runs the rest once the pane's terminal is resized.
It execs the command on the first SIGWINCH, or after
`emrex-resize-wait' seconds; empty when that is nil."
  (when emrex-resize-wait
    (list "/bin/sh" "-c"
          (format "trap 'exec \"$0\" \"$@\"' WINCH; sleep %s & wait; exec \"$0\" \"$@\""
                  emrex-resize-wait))))

(cl-defun emrex--spawn (window direction &key focus file read-only ratio)
  "Open a Rex pane DIRECTION of WINDOW's pane, running emacsclient.
DIRECTION is \"left\", \"right\", \"above\" or \"below\".  The new pane
shows FILE, opened read-only if READ-ONLY is non-nil, or else WINDOW's
buffer at WINDOW's point.  FOCUS non-nil means Rex focuses the new pane.
RATIO is the new pane's share of the split, in percent.

Return at once: the pane is set up when its emacsclient connects, which
must not happen while a command runs.  Emacs then reads only the
command's terminal, so the new terminal couldn't answer the queries Emacs
and packages such as kkp send it while setting it up."
  (let* ((frame (window-frame window))
         (id (cl-incf emrex--spawn-count)))
    (puthash id (emrex--spawn-create
                 :origin frame :buffer (window-buffer window)
                 :point (window-point window) :start (window-start window)
                 :file file :read-only read-only)
             emrex--spawns)
    (apply #'emrex--rex-async frame (lambda () (remhash id emrex--spawns))
           `("split" "--block" ,(emrex--block frame) "--split" ,direction
             ,(if focus "--focus=true" "--focus=false")
             ,@(and ratio (list "--ratio" (number-to-string ratio)))
             "--shell=none" "--"
             ,@(emrex--after-resize)
             ,(emrex--emacsclient) "-t" "-u" ,@(emrex--server-args)
             "-e" ,(format "(emrex--adopt %d)" id)))
    nil))

(defun emrex--share-perspective (origin frame)
  "Show ORIGIN's persp-mode perspective in FRAME.
Drops the perspective persp-mode made for FRAME, unless another frame
shows it, and unties FRAME from the shared one so that deleting FRAME
doesn't kill it (Doom kills a frame's `workspace' when the frame goes)."
  (when (and (bound-and-true-p persp-mode) (frame-live-p origin))
    (let ((shared (get-frame-persp origin))
          (own (get-frame-persp frame)))
      (unless (eq shared own)
        (persp-frame-switch (safe-persp-name shared) frame)
        (set-frame-parameter frame 'workspace nil)
        (when (and own (null (persp-frames-with-persp own)))
          (persp-kill (safe-persp-name own) t))))))

(defun emrex--adopt (id)
  "Set up the selected frame as the pane of spawn ID.
A new pane's emacsclient evaluates this once its frame exists."
  (when-let* ((spawn (gethash id emrex--spawns)))
    (remhash id emrex--spawns)
    (let* ((frame (selected-frame))
           (window (frame-selected-window frame)))
      (condition-case err
          (progn
            (emrex--share-perspective (emrex--spawn-origin spawn) frame)
            (cond
             ((emrex--spawn-file spawn)
              (find-file (emrex--spawn-file spawn))
              (when (emrex--spawn-read-only spawn)
                (read-only-mode 1)))
             ((buffer-live-p (emrex--spawn-buffer spawn))
              (set-window-buffer window (emrex--spawn-buffer spawn))
              (when-let* ((start (emrex--spawn-start spawn)))
                (set-window-start window start t))
              (when-let* ((point (emrex--spawn-point spawn)))
                (set-window-point window point))))
            ;; The buffer emacsclient opened with isn't this window's history.
            (set-window-prev-buffers window nil)
            (set-window-next-buffers window nil))
        (error (message "emrex: %s" (error-message-string err))))))
  nil)

;;;; Splitting

(defun emrex--ratio (window direction lines)
  "The --ratio giving a pane split DIRECTION from WINDOW's LINES or columns."
  (let ((total (if (member direction '("left" "right"))
                   (window-total-width window)
                 (window-total-height window))))
    (max 5 (min 95 (round (* 100.0 lines) total)))))

(defun emrex--split (direction focus &optional lines file read-only)
  "Open a pane DIRECTION of the selected one, showing its buffer or FILE.
FOCUS non-nil focuses the new pane.  LINES non-nil gives it that many
lines or columns.  READ-ONLY non-nil opens FILE read-only."
  (let ((window (selected-window)))
    (emrex--spawn window direction
                  :focus focus
                  :file (and file (expand-file-name file))
                  :read-only read-only
                  :ratio (and lines (emrex--ratio window direction lines)))))

(defun emrex--new-lines (size total)
  "Lines or columns the new window gets from `split-window-below' SIZE.
TOTAL is the size of the window being split."
  (when size
    (let ((size (prefix-numeric-value size)))
      (if (< size 0) (- size) (- total size)))))

(defun emrex-split-window-below (&optional size)
  "Like `split-window-below', but in a Rex pane open a new pane below.
SIZE is as for `split-window-below'.  The selected window stays selected."
  (interactive "P")
  (if (emrex--pane-p)
      (emrex--split "below" nil (emrex--new-lines size (window-total-height)))
    (split-window-below size)))

(defun emrex-split-window-right (&optional size)
  "Like `split-window-right', but in a Rex pane open a new pane to the right.
SIZE is as for `split-window-right'.  The selected window stays selected."
  (interactive "P")
  (if (emrex--pane-p)
      (emrex--split "right" nil (emrex--new-lines size (window-total-width)))
    (split-window-right size)))

;;;; Deleting

(defun emrex-delete-window ()
  "Like `delete-window', but close a Rex pane when deleting its only window."
  (interactive)
  (if (emrex--sole-window-p)
      (delete-frame)
    (call-interactively #'delete-window)))

(defun emrex-close-window-or-workspace ()
  "Like Doom's `+workspace/close-window-or-workspace', for Rex panes.
Closing a pane's only window closes the pane, not the workspace."
  (interactive)
  (if (emrex--sole-window-p)
      (delete-frame)
    (call-interactively #'+workspace/close-window-or-workspace)))

(defun emrex--other-panes (frame)
  "The other managed frames in FRAME's Rex window, least recently used first.
Asks Rex which window each is in only when FRAME's Rex session has other
managed frames."
  (let* ((session (getenv "REX_SESSION" frame))
         (others (seq-filter (lambda (f)
                               (and (not (eq f frame))
                                    (emrex--block f)
                                    (equal (getenv "REX_SESSION" f) session)))
                             (frame-list))))
    (when others
      (let* ((blocks (alist-get 'blocks
                                (json-parse-string
                                 (emrex--rex frame "block" "ls" "--json"
                                             "--session" session)
                                 :object-type 'alist :array-type 'list)))
             (rex-window (lambda (f)
                           (alist-get 'window_id
                                      (seq-find (lambda (b)
                                                  (equal (alist-get 'block_id b)
                                                         (emrex--block f)))
                                                blocks))))
             (here (funcall rex-window frame)))
        (when here
          (sort (seq-filter (lambda (f) (equal (funcall rex-window f) here))
                            others)
                :key (lambda (f) (window-use-time (frame-selected-window f)))))))))

(defun emrex--close-other-panes (frame)
  "Delete the other managed frames in FRAME's Rex window."
  (dolist (other (emrex--other-panes frame))
    (condition-case err
        (delete-frame other)
      (error (message "emrex: %s" (error-message-string err))))))

(defun emrex-delete-other-windows ()
  "Like `delete-other-windows', and close the other Emacs panes too.
Only Emacs panes in the same Rex window close; a pane that started as a
shell goes back to its shell."
  (interactive)
  (if (not (emrex--pane-p))
      (call-interactively #'delete-other-windows)
    (unless (one-window-p 'nomini)
      (call-interactively #'delete-other-windows))
    (emrex--close-other-panes (selected-frame))))

;;;; Moving

(defun emrex--step (direction)
  "Select the window DIRECTION (`next' or `prev') in this pane, or else in Rex."
  (let* ((windows (seq-remove (lambda (w) (window-parameter w 'no-other-window))
                              (window-list nil 'nomini (frame-first-window))))
         (rest (memq (selected-window)
                     (if (eq direction 'next) windows (reverse windows)))))
    (if (cadr rest)
        (select-window (cadr rest))
      (emrex--focus (selected-frame) (symbol-name direction) "--wrap"))))

(defun emrex--move (direction)
  "Select the window DIRECTION of this one in the pane, or else in Rex.
DIRECTION is `left', `right', `up' or `down'."
  (if-let* ((window (window-in-direction
                     (pcase direction ('up 'above) ('down 'below) (_ direction)))))
      (select-window window)
    (emrex--focus (selected-frame) (symbol-name direction))))

(defun emrex-other-window (count)
  "Like `other-window', but past this pane's last window go to the next pane.
In a Rex pane only the sign of COUNT matters: negative goes backwards."
  (interactive "p")
  (cond ((not (emrex--pane-p)) (call-interactively #'other-window))
        ((< count 0) (emrex--step 'prev))
        ((> count 0) (emrex--step 'next))))

;;;; Focus

(defvar emrex--command-frame nil
  "The frame selected when the current command started.")

(defun emrex--note-frame-h ()
  "Remember the selected frame, for `emrex--follow-selection-h'."
  (setq emrex--command-frame (selected-frame)))

(defun emrex--follow-selection-h ()
  "Focus the pane of a window the last command selected in another pane.
Not after the command's own frame went: Rex picks the pane to focus then."
  (let ((frame (selected-frame)))
    (when-let* (((not (eq frame emrex--command-frame)))
                ((frame-live-p emrex--command-frame))
                ((not (eq this-command 'handle-switch-frame)))
                (block (emrex--block frame)))
      (emrex--focus frame block))))

;;;; Sizes

(defcustom emrex-size-check-interval 1.0
  "Seconds between checks that each pane's frame matches its terminal size.
Rex sometimes resizes several panes at once and Emacs drops one of the
resulting size updates, leaving that frame drawn at its old size.  nil
turns the check off."
  :type '(choice (const :tag "Off" nil) number))

(defvar emrex--size-timer nil
  "Timer for `emrex--refresh-sizes'.")

(defun emrex--refresh-sizes ()
  "Ask Emacs to reread its terminals' sizes when a Rex pane is open.
SIGWINCH makes Emacs compare each terminal's size with its frame's, and
update only the frames that differ."
  (when (seq-some (lambda (frame) (emrex--block frame)) (frame-list))
    (signal-process (emacs-pid) 'SIGWINCH)))

;;;; display-buffer

(defun emrex-display-buffer (buffer alist)
  "Display BUFFER in another Emacs pane of this Rex window.
An action function for `display-buffer', which `emrex-mode' adds to
`display-buffer-base-action'; ALIST is as for that.  Use a pane showing
BUFFER, else the least recently used pane whose window isn't dedicated.

Return nil, so `display-buffer' goes on as usual, outside Rex, for
buffers Emacs shows in the selected window, when this pane already shows
BUFFER in a window `display-buffer' may use, or with no other pane."
  (let ((inhibit-same (cdr (assq 'inhibit-same-window alist))))
    (when-let* (((emrex--pane-p))
                ((or inhibit-same (not (same-window-p (buffer-name buffer)))))
                (frame (selected-frame))
                ((not (seq-some (lambda (w)
                                  (not (and inhibit-same (eq w (selected-window)))))
                                (get-buffer-window-list buffer 'nomini frame))))
                (panes (condition-case err
                           (emrex--other-panes frame)
                         (error (message "%s" (error-message-string err))
                                nil)))
                (window (or (seq-find (lambda (w) (memq (window-frame w) panes))
                                      (get-buffer-window-list buffer 'nomini t))
                            (seq-find (lambda (w) (not (window-dedicated-p w)))
                                      (mapcar #'frame-selected-window panes)))))
      (window--display-buffer buffer window 'reuse alist))))

;;;; Evil

(defun emrex--evil-split-a (fn &rest args)
  "Open `evil-window-split''s window as a Rex pane.  FN takes ARGS."
  (if (emrex--pane-p)
      (emrex--split (if evil-split-window-below "below" "above") t
                    (nth 0 args) (nth 1 args) (nth 2 args))
    (apply fn args)))

(defun emrex--evil-vsplit-a (fn &rest args)
  "Open `evil-window-vsplit''s window as a Rex pane.  FN takes ARGS."
  (if (emrex--pane-p)
      (emrex--split (if evil-vsplit-window-right "right" "left") t
                    (nth 0 args) (nth 1 args) (nth 2 args))
    (apply fn args)))

(defun emrex--evil-close-a (fn &rest args)
  "Close the pane when `evil-window-delete' or `evil-quit' ends its only window.
`evil-quit' would otherwise fall back to `server-edit', which finishes
the buffer for every client showing it, not just this pane's.  FN takes
ARGS."
  (if (emrex--sole-window-p)
      (delete-frame)
    (apply fn args)))

(defun emrex--evil-step (direction fn args)
  "Step to the DIRECTION window through Rex, unless ARGS has a count for FN."
  (if (and (emrex--pane-p) (null (car args)))
      (emrex--step direction)
    (apply fn args)))

(defun emrex--evil-next-a (fn &rest args)
  "Let `evil-window-next' reach other panes.  FN takes ARGS."
  (emrex--evil-step 'next fn args))

(defun emrex--evil-prev-a (fn &rest args)
  "Let `evil-window-prev' reach other panes.  FN takes ARGS."
  (emrex--evil-step 'prev fn args))

(defun emrex--evil-move (direction fn args)
  "Move DIRECTION through Rex, unless ARGS has a count above 1 for FN."
  (if (and (emrex--pane-p) (<= (or (car args) 1) 1))
      (emrex--move direction)
    (apply fn args)))

(defun emrex--evil-left-a (fn &rest args)
  "Let `evil-window-left' reach other panes.  FN takes ARGS."
  (emrex--evil-move 'left fn args))

(defun emrex--evil-right-a (fn &rest args)
  "Let `evil-window-right' reach other panes.  FN takes ARGS."
  (emrex--evil-move 'right fn args))

(defun emrex--evil-up-a (fn &rest args)
  "Let `evil-window-up' reach other panes.  FN takes ARGS."
  (emrex--evil-move 'up fn args))

(defun emrex--evil-down-a (fn &rest args)
  "Let `evil-window-down' reach other panes.  FN takes ARGS."
  (emrex--evil-move 'down fn args))

(defconst emrex--advice
  '((evil-window-split . emrex--evil-split-a)
    (evil-window-vsplit . emrex--evil-vsplit-a)
    (evil-window-delete . emrex--evil-close-a)
    (evil-quit . emrex--evil-close-a)
    (evil-window-next . emrex--evil-next-a)
    (evil-window-prev . emrex--evil-prev-a)
    (evil-window-left . emrex--evil-left-a)
    (evil-window-right . emrex--evil-right-a)
    (evil-window-up . emrex--evil-up-a)
    (evil-window-down . emrex--evil-down-a))
  "Functions `emrex-mode' advises, with their :around advice.
Evil's window commands are advised rather than remapped so that ex
commands such as :split reach them too.")

(defun emrex--define-only ()
  "Point evil's :only at `emrex-delete-other-windows'."
  (when emrex-mode
    (evil-ex-define-cmd "on[ly]" #'emrex-delete-other-windows)))

;;;; Mode

(defvar emrex-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap split-window-below] #'emrex-split-window-below)
    (define-key map [remap split-window-right] #'emrex-split-window-right)
    (define-key map [remap delete-window] #'emrex-delete-window)
    (define-key map [remap delete-other-windows] #'emrex-delete-other-windows)
    (define-key map [remap other-window] #'emrex-other-window)
    (define-key map [remap +workspace/close-window-or-workspace]
                #'emrex-close-window-or-workspace)
    map)
  "Keymap for `emrex-mode'.
Remaps Emacs's window commands rather than advising them, since other
code calls those as functions and expects windows in the same frame.")

(defun emrex--base-action (enable)
  "`display-buffer-base-action' with `emrex-display-buffer' first if ENABLE."
  (let* ((functions (car display-buffer-base-action))
         (functions (remq #'emrex-display-buffer
                          (if (functionp functions) (list functions) functions))))
    (cons (if enable (cons #'emrex-display-buffer functions) functions)
          (cdr display-buffer-base-action))))

;;;###autoload
(define-minor-mode emrex-mode
  "Make the windows of Emacs in Rex panes into Rex panes.
In a frame emacsclient made in a Rex pane, splitting a window opens a
new pane running emacsclient on this server, deleting a pane's only
window closes the pane, and window motion continues through Rex.  Other
frames are unaffected.  See the Commentary of emrex.el."
  :global t
  :group 'emrex
  (if emrex-mode
      (progn
        (add-hook 'pre-command-hook #'emrex--note-frame-h)
        (add-hook 'post-command-hook #'emrex--follow-selection-h)
        (when emrex-size-check-interval
          (setq emrex--size-timer (run-with-timer emrex-size-check-interval
                                                  emrex-size-check-interval
                                                  #'emrex--refresh-sizes)))
        (pcase-dolist (`(,fn . ,advice) emrex--advice)
          (advice-add fn :around advice))
        (setq display-buffer-base-action (emrex--base-action t))
        (with-eval-after-load 'evil (emrex--define-only)))
    (remove-hook 'pre-command-hook #'emrex--note-frame-h)
    (remove-hook 'post-command-hook #'emrex--follow-selection-h)
    (when emrex--size-timer
      (cancel-timer emrex--size-timer)
      (setq emrex--size-timer nil))
    (pcase-dolist (`(,fn . ,advice) emrex--advice)
      (advice-remove fn advice))
    (setq display-buffer-base-action (emrex--base-action nil))
    (when (featurep 'evil)
      (evil-ex-define-cmd "on[ly]" #'delete-other-windows))))

(provide 'emrex)
;;; emrex.el ends here

;;; magithub.el --- Magit interfaces for GitHub  -*- lexical-binding: t; -*-

;; Copyright (C) 2016-2017  Sean Allred

;; Author: Sean Allred <code@seanallred.com>
;; Keywords: git, tools, vc
;; Homepage: https://github.com/vermiculus/magithub
;; Package-Requires: ((emacs "24.4") (magit "2.8.0") (git-commit "20160821.1338") (with-editor "20160828.1025") (s "20160711.525") (ghub+ "20161119.2004") (markdown-mode "20161222.1416"))
;; Package-Version: 0.1

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Magithub is an interface to GitHub using the `hub' utility [1].
;;
;; Integrated into Magit workflows, Magithub allows very easy, very
;; basic GitHub repository management.  Supported actions include:
;;
;;  - pushing brand-new local repositories up to GitHub
;;  - creating forks of existing repositories
;;  - submitting pull requests upstream
;;  - viewing and creating issues
;;
;; Press `H' in the status buffer to get started -- happy hacking!
;;
;; [1]: https://hub.github.com

;; Requires hub 2.2.8

;;; Code:

(require 'magit)
(require 'magit-process)
(require 'magit-popup)
(require 'git-commit)
(require 'with-editor)
(require 'cl-lib)
(require 's)
(require 'dash)

(require 'magithub-core)
(require 'magithub-issue)
(require 'magithub-cache)
(require 'magithub-ci)
(require 'magithub-proxy)
(require 'magithub-issue-status)

(magit-define-popup magithub-dispatch-popup
  "Popup console for dispatching other Magithub popups."
  'magithub-commands
  :man-page "hub"
  :actions '("Actions"
             (?H "Browse on GitHub" magithub-browse)
             (?c "Create" magithub-create-popup)
             (?f "Fork" magithub-fork-popup)
             (?i "Issues" magithub-issues-popup)
             (?p "Submit a pull request" magithub-pull-request-popup)
             (?x "Use a proxy repository for issues/PRs" magithub-proxy-set)
             "Meta"
             (?` "Toggle Magithub-Status integration" magithub-enabled-toggle)
             (?g "Refresh all GitHub data" magithub-refresh)
             (?& "Request a feature or report a bug" magithub--meta-new-issue)
             (?h "Ask for help on Gitter" magithub--meta-help)))

(magit-define-popup-action 'magit-dispatch-popup
  ?H "Magithub" #'magithub-dispatch-popup ?!)
(define-key magit-status-mode-map
  "H" #'magithub-dispatch-popup)

(magit-define-popup magithub-create-popup
  "Popup console for creating GitHub repositories."
  'magithub-commands
  :man-page "hub"
  :switches '((?p "Mark as private" "-p"))
  :actions '((?c "Create this repository" magithub-create))
  :options '((?d "Description" "--description=")
             (?h "Homepage" "--homepage=")))

(magit-define-popup magithub-fork-popup
  "Popup console for forking GitHub repositories."
  'magithub-commands
  :man-page "hub"
  :switches '((?r "Don't add my fork as a remote in this repository" "--no-remote"))
  :actions '((?f "Fork the project at origin" magithub-fork)))

(magit-define-popup magithub-pull-request-popup
  "Popup console for creating pull requests on GitHub repositories."
  'magithub-commands
  :man-page "hub"
  :switches '((?f "Ignore unpushed commits" "-f")
              (?o "Open in my browser" "-o"))
  :options '((?b "Base branch" "--base=" magit-read-branch)
             (?h "Head branch" "--head=" magit-read-branch))
  :actions '((?P "Submit a pull request" magithub-pull-request))
  :default-arguments '("-o"))

(defun magithub-browse ()
  "Open the repository in your browser."
  (interactive)
  (unless (magithub-github-repository-p)
    (user-error "Not a GitHub repository"))
  (browse-url (let-alist (magithub-source-repo t t) .html_url)))

(defvar magithub-after-create-messages
  '("Don't be shy!"
    "Don't let your dreams be dreams!")
  "One of these messages will be displayed after you create a
GitHub repository.")

(defvar magithub-preferred-remote-method 'ssh_url
  "Preferred method when cloning or adding remotes.
One of the following:

  `clone_url' (https://github.com/octocat/Hello-World.git)
  `git_url'   (git:github.com/octocat/Hello-World.git)
  `ssh_url'   (git@github.com:octocat/Hello-World.git)")
(defun magithub-create (repo)
  "Create the current repository on GitHub."
  (interactive (list (unless (or (magithub-github-repository-p) (not (magit-toplevel)))
                       `((name . ,(magithub--read-repo-name (ghub--username)))
                         (description . ,(read-string "Description (optional): "))))))
  (when (magithub-github-repository-p)
    (error "Already in a GitHub repository"))
  (if (not (magit-toplevel))
      (when (y-or-n-p "Not inside a Git repository; initialize one here? ")
        (magit-init default-directory)
        (call-interactively #'magithub-create))
    (with-temp-message "Creating repository on GitHub..."
      (setq repo (ghubp-post-user-repos repo)))
    (magithub--random-message "Creating repository on GitHub...done!")
    (magit-status-internal default-directory)
    (magit-remote-add "origin" (alist-get magithub-preferred-remote-method repo))
    (magit-refresh)
    (when (magit-rev-verify "HEAD")
      (magit-push-popup))))

(defun magithub--read-repo-name (for-user)
  (let* ((for-user "vermiculus")
         (prompt (format "Repository name: %s/" for-user))
         (dirnam (file-name-nondirectory (substring default-directory 0 -1)))
         (valid-regexp (rx bos (+ (any alnum "." "-" "_")) eos))
         ret)
    ;; This is not very clever, but it gets the job done.  I'd like to
    ;; either have instant feedback on what's valid or not allow users
    ;; to enter invalid names at all.  Could code from Ivy be used?
    (while (not (s-matches-p valid-regexp (setq ret (read-string prompt nil nil dirnam))))
      (message "invalid name")
      (sit-for 1))
    ret))

(defun magithub--random-message (&optional prefix)
  (let ((msg (nth (random (length magithub-after-create-messages))
                  magithub-after-create-messages)))
    (if prefix (format "%s  %s" prefix msg) msg)))

(defun magithub-fork ()
  "Fork 'origin' on GitHub."
  (interactive)
  (unless (magithub-github-repository-p)
    (user-error "Not a GitHub repository"))
  (when (and (s-equals? "master" (magit-get-current-branch))
             (y-or-n-p "Looks like master is checked out.  Create a new branch? "))
    (call-interactively #'magit-branch-spinoff))
  (let ((repo (magithub-source-repo)))
    (with-temp-message "Forking repository on GitHub..."
      (ghubp-post-repos-owner-repo-forks repo))
    (magithub--random-message
     (let-alist repo (format "%s/%s forked!" .owner.login .name)))))

(defun magithub-pull-request ()
  "Open a pull request to 'origin' on GitHub."
  (interactive)
  (unless (magithub-github-repository-p)
    (user-error "Not a GitHub repository"))
  (let (just-pushed)
    (unless (magit-get-push-remote)
      (when (y-or-n-p "No push remote defined; push now? ")
        (call-interactively #'magit-push-current-to-pushremote)
        (setq just-pushed t)))
    (unless (magit-get-push-remote)
      (user-error "No push remote defined; aborting pull request"))
    (unless just-pushed
      (when (y-or-n-p "Do you want to push any more commits? ")
        (magit-push-popup)))
    (magithub--command-with-editor "pull-request" (magithub-pull-request-arguments))))

(defface magithub-issue-warning-face
  '((((class color)) :inherit warning))
  "Face used to call out warnings in the issue-create buffer."
  :group 'magithub)

(defun magithub-setup-edit-buffer ()
  "Perform setup on a hub edit buffer."
  (with-editor-mode 1)
  (git-commit-setup-font-lock)
  (font-lock-add-keywords
   nil `((,magithub-hash-regexp (0 'magit-hash t))) t)
  (add-hook
   (make-local-variable 'with-editor-pre-finish-hook)
   (lambda ()
     (let ((fill-column (point-max)))
       (fill-region (point-min) (point-max))))))

(defun magithub-setup-new-issue-buffer ()
  "Setup the buffer created for issue-posting."
  (font-lock-add-keywords
   nil '(("^# \\(Creating issue for .*\\)" (1 'magithub-issue-warning-face t))) t))

(defvar magithub--file-types
  '(("ISSUE_EDITMSG" . issue)
    ("PULLREQ_EDITMSG" . pull-request))
  "File types -- car is the basename of a file in /.git/, cdr is
  one of `issue' or `pull-request'.")

(defun magithub--edit-file-type (path)
  "Determine the type of buffer this is (if it was created by hub).
Returns `issue', `pull-request', or another non-nil value if
created by hub.

This function will return nil for matches to
`git-commit-filename-regexp'."
  (when (and path (magit-inside-gitdir-p))
    (let ((basename (file-name-base path)))
      (and (not (s-matches? git-commit-filename-regexp basename))
           (cdr (assoc basename magithub--file-types))))))

(defun magithub-check-buffer ()
  "If this is a buffer created by hub, perform setup."
  (when-let ((filetype (magithub--edit-file-type buffer-file-name)))
    (magithub-setup-edit-buffer)
    (when (eq filetype 'issue)
      (magithub-setup-new-issue-buffer))))
(add-hook 'find-file-hook #'magithub-check-buffer)

(defun magithub-clone--get-repo ()
  "Prompt for a user and a repository.
Returns a list (USER REPOSITORY)."
  (let ((user (getenv "GITHUB_USER"))
        (repo-regexp  (rx bos (group (+ (not (any " "))))
                          "/" (group (+ (not (any " ")))) eos))
        repo)
    (while (not (and repo (string-match repo-regexp repo)))
      (setq repo (read-from-minibuffer
                  (concat
                   "Clone GitHub repository "
                   (if repo "(format is \"user/repo\"; C-g to quit)" "(user/repo)")
                   ": ")
                  (when user (concat user "/")))))
    (list (match-string 1 repo)
          (match-string 2 repo))))

(defcustom magithub-clone-default-directory nil
  "Default directory to clone to when using `magithub-clone'.
When nil, the current directory at invocation is used."
  :type 'directory
  :group 'magithub)

(defun magithub-clone (user repo dir)
  "Clone USER/REPO.
Banned inside existing GitHub repositories if
`magithub-clone-default-directory' is nil."
  (interactive (if (and (not magithub-clone-default-directory)
                        (magithub-github-repository-p))
                   (user-error "Already in a GitHub repo")
                 (let ((args (magithub-clone--get-repo)))
                   (append args (list (read-directory-name
                                       "Destination: "
                                       (if (s-ends-with? "/" magithub-clone-default-directory)
                                           magithub-clone-default-directory
                                         (concat magithub-clone-default-directory "/"))
                                       nil nil
                                       (cadr args)))))))
  (unless (file-writable-p dir)
    (user-error "%s does not exist or is not writable" dir))
  (when (y-or-n-p (format "Clone %s/%s to %s? " user repo dir))
    (let* ((proc (start-process "*magithub-clone*" "*magithub-clone*"
                                magithub-hub-executable
                                "clone"
                                (format "%s/%s" user repo)
                                dir)))
      (set-process-sentinel
       proc
       (lambda (p event)
         (setq event (s-trim event))
         (cond ((string= event "finished")
                (run-with-idle-timer 1 nil #'magithub-clone--finished user repo dir))
               (t (pop-to-buffer (process-buffer p))
                  (message "unhandled event: %s => %s" (process-command p) event))))))))

(defun magithub-clone--finished (user repo dir)
  "After finishing the clone, allow the user to jump to their new repo."
  (when (y-or-n-p (format "%s/%s has finished cloning to %s.  Open? " user repo dir))
    (magit-status-internal (s-chop-suffix "/" dir))))

(defun magithub-feature-autoinject (feature)
  "Configure FEATURE to recommended settings.
If FEATURE is `all' ot t, all known features will be loaded."
  (if (memq feature '(t all))
      (mapc #'magithub-feature-autoinject magithub-feature-list)
    (cl-case feature

      (pull-request-merge
       (magit-define-popup-action 'magit-am-popup
         ?P "Apply patches from pull request" #'magithub-pull-request-merge))

      (pull-request-checkout
       (magit-define-popup-action 'magit-branch-popup
         ?P "Checkout pull request" #'magithub-pull-request-checkout))

      (t (user-error "unknown feature %S" feature)))
    (add-to-list 'magithub-features (cons feature t))))


(defun magithub-visit-thing (choose-thing)
  (interactive "P")
  (let-alist (magithub-thing-at-point 'all)
    (cond (.label (magithub-label-browse .label))
          (.issue (magithub-issue-browse .issue))
          (.pull-request (magithub-pull-browse .pull-request))
          (t (message "Nothing recognizable at point")))))

(provide 'magithub)
;;; magithub.el ends here

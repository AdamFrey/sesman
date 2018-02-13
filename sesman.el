;;; sesman.el --- Session and connection manager interface -*- lexical-binding: t -*-
;;
;; Copyright (C) 2018, Vitalie Spinu
;; Author: Vitalie Spinu
;; URL: https://github.com/vspinu/sesman
;; Keywords: process
;; Version: 0.0.1
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This file is *NOT* part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Code:

(require 'project)
(require 'mule-util)
(require 'seq)

(defgroup sesman nil
  "Session manager."
  :prefix "sesman")

(defvar sesman-sessions (make-hash-table :test #'equal)
  "Hashtable of all sesman sessions.
Key is a cons (system-name . session-name).")
(defvar sesman-links nil
  "An alist of all sesman associations.
Each element is of the form (key cxt-type cxt-value) where
\"key\" is of the form (system-name . session-name).")


;;; User Interface

(defcustom sesman-1-to-1-links '(directory buffer)
  "List of context types for which links should be 1-to-1."
  :group 'sesman
  :type '(repeat symbol))

(defun sesman-start ()
  "Start sesman session."
  (interactive)
  (let ((session (sesman-start-session (sesman--system))))
    (sesman-register session)
    (message "Started %s" (car session))))

(defun sesman-restart ()
  "Restart sesman session."
  (interactive)
  (let* ((system (sesman--system))
         (old-session (sesman-ensure-session "Restart session: "))
         (old-session (sesman-unregister old-session system))
         (new-session (sesman-restart-session system old-session)))
    (sesman-register new-session system)
    (message "Restarted %s" (car old-session))
    new-session))

(defun sesman-kill ()
  "Kill sesman session."
  (interactive)
  (let ((sessions (sesman-ensure-session "Kill session: " nil 'ask-all))
        (system (sesman--system)))
    (mapc (lambda (s)
            (sesman-unregister s system)
            (sesman-kill-session system s))
          sessions)
    (message "Killed %s" (mapcar #'car sessions))))

(defun sesman-link-with-buffer ()
  "Associate a session with current buffer."
  (interactive)
  (sesman--link-session-interactively buffer))

(defun sesman-link-with-directory ()
  "Associate a session with current directory."
  (interactive)
  (sesman--link-session-interactively directory))

(defun sesman-link-with-project ()
  "Associate a session with current project."
  (interactive)
  (sesman--link-session-interactively project))

(defun sesman-unlink (&optional arg)
  "Break any of the previously formed associations."
  (interactive "P")
  (let* ((links (or (sesman--current-links)
                    (user-error "No %s associations found" (sesman--system)))))
    (mapc #'sesman--unlink
          (sesman--ask-for-link "Unlink: " links 'ask-all))))

(defvar sesman-map
  (let (sesman-map)
    (define-prefix-command 'sesman-map)
    (define-key sesman-map (kbd "C-s") 'sesman-start)
    (define-key sesman-map (kbd   "s") 'sesman-start)
    (define-key sesman-map (kbd "C-r") 'sesman-restart)
    (define-key sesman-map (kbd   "r") 'sesman-restart)
    (define-key sesman-map (kbd "C-k") 'sesman-kill)
    (define-key sesman-map (kbd   "k") 'sesman-kill)
    (define-key sesman-map (kbd "C-b") 'sesman-link-with-buffer)
    (define-key sesman-map (kbd   "b") 'sesman-link-with-buffer)
    (define-key sesman-map (kbd "C-d") 'sesman-link-with-directory)
    (define-key sesman-map (kbd   "d") 'sesman-link-with-directory)
    (define-key sesman-map (kbd "C-p") 'sesman-link-with-project)
    (define-key sesman-map (kbd   "p") 'sesman-link-with-project)
    (define-key sesman-map (kbd "C-u") 'sesman-unlink)
    (define-key sesman-map (kbd "  u") 'sesman-unlink)
    sesman-map)
  "Session management prefix keymap.")


;;; System Interface

(defvar-local sesman-system nil
  "Name of the system managed by `sesman'.
Can be either a symbol, or a function returning a symbol.")

(cl-defgeneric sesman-context-types (system)
  "Return a list of context types understood by SYSTEM."
  '(buffer directory project))

(cl-defgeneric sesman-start-session (system &optional session)
  "Start and return SYSTEM SESSION.
A session is a list with first element being a name.  When
present SESSION is an old session (typically during the session
restart) and could be safely (re-)used.")

(cl-defgeneric sesman-kill-session (system session)
  "Kill SYSTEM SESSION.")

(cl-defgeneric sesman-restart-session (system session)
  "Restart SYSTEM SESSION.
By default, calls `sesman-kill-session' and then
`sesman-start-session'."
  (let ((old-name (car session)))
    (sesman-kill-session system session)
    (let ((new-session (sesman-start-session system session)))
      (setcar new-session old-name)
      new-session)))

(cl-defgeneric sesman-greater-p (system session1 session2)
  "Return non-nil if SESSION1 should be sorted before SESSION2.
By default, sort by session name.  Systems should overwrite this
method to provide a more meaningful ordering; ideally more
recently used session should score higher."
  (string-greaterp (car session1) (car session2)))

(cl-defgeneric sesman-friendly-session-p (system session)
  "Non-nil if SYSTEM's SESSION is friendly to current context.
A friendly session is the one for which it makes sense to create
an association with current contexts.  For example, if the user
is within the project A which is required (dependent upon) from
project B, then a session opened within project B is a friendly
session for current context.  By default, there are no friendly
sessions."
  ;; by default no friendly sessions
  nil)

(defun sesman-ensure-session (&optional prompt ask-new ask-all)
  "Ensure that at least one session is linked and return most relevant one.
If there is an unambiguous link, return the linked session.  In
case of multiple associations, ask the user for a session with
PROMPT.  When ASK-NEW is non-nil, offer *new* option to start a
new session.  If ASK-ALL is non-nil offer *all* option to return
the sessions.  If ASK-ALL is non-nil, return a list of sessions."
  (let ((prompt (or prompt "Session: "))
        (sessions (sesman-linked-sessions)))
    (cond
     ;; 1. Single association; return
     ((and (eq (length sessions) 1)
           (not ask-new)
           (not ask-all))
      (car sessions))
     ;; 2. Multiple associations; ask
     (sessions
      (sesman--ask-for-session prompt sessions ask-new ask-all))
     ;; 3. No associations, get all friendly sessions and ask
     (t (let ((sessions (sesman-friendly-sessions)))
          (sesman--ask-for-session prompt sessions ask-new ask-all))))))

(defun sesman-linked-session (&optional system cxt-types)
  "Get the most relevant linked session for SYSTEM.
CXT-TYPES is as in `sesman-linked-sessions'."
  (car (sesman-linked-sessions system cxt-types)))

(defun sesman-linked-sessions (&optional system cxt-types)
  "Return a list of SYSTEM sessions linked in current context.
CXT-TYPES is a list of context types to considere. Defaults to
the list returned from `sesman-context-types'."
  (let* ((system (or system (sesman--system)))
         (cxt-types (or cxt-types (sesman-context-types system))))
    ;; just in case some links are lingering due to user errors
    (sesman--clear-links)
    (mapcar (lambda (assoc)
              (gethash (car assoc) sesman-sessions))
            (sesman--current-links system cxt-types))))

(defun sesman-friendly-sessions (&optional system)
  "Return a list of friendly (for current context) SYSTEM sessions.
Session is friendly if `sesman-friendly-session-p' returns non-nil."
  (let ((system (or system (sesman--system)))
        sessions)
    (maphash
     (lambda (k s)
       (when (and (eql (car k) system)
                  (sesman-friendly-session-p system s))
         (push s sessions)))
     sesman-sessions)
    (sesman--sort-sessions system sessions)))

(defun sesman-system-sessions (&optional system)
  "Return a list of sessions registered with SYSTEM."
  (let ((system (or system (sesman--system)))
        sessions)
    (maphash
     (lambda (k s)
       (when (eql (car k) system)
         (push s sessions)))
     sesman-sessions)
    (sesman--sort-sessions system sessions)))

(defun sesman-sessions (&optional system)
  "Return all sessions for SYSTEM.
Return a list of `sesman-linked-sessions',
`sesman-friendly-sessions' and all other `sesman-system-sessions'
in that order."
  (let* ((system (or system (sesman--system))))
    (delete-dups
     (append (sesman-linked-sessions system)
             (sesman-friendly-sessions system)
             (sesman-system-sessions system)))))

(defun sesman-register (session &optional system)
  "Register SESSION into `sesman-sessions' and `sesman-links'.
SYSTEM defaults to current system.  If a session with same name
is already registered in `sesman-sessions', change the name by
appending \"<1>\", \"<2>\" ... to the name.  This function should
be called by legacy connection initializers (\"run-xyz\",
\"xyz-jack-in\" etc.)."
  (let* ((system (or system (sesman--system)))
         (ses-name (car session))
         (i 1))
    (while (gethash (cons system ses-name) sesman-sessions)
      (setq ses-name (format "%s<%d>" i)))
    (setq session (cons ses-name (cdr session)))
    (puthash (cons system ses-name) session sesman-sessions)
    (sesman--link-session session system)
    session))

(defun sesman-unregister (session &optional system)
  "Unregister SESSION.
SYSTEM defaults to current system.  Remove session from
`sesman-sessions' and `sesman-links'."
  (let ((system (or system (sesman--system)))
        (ses-key (cons system (car session))))
    (remhash ses-key sesman-sessions)
    (sesman--clear-links)
    session))


;;; Contexts

(cl-defgeneric sesman-context (cxt-type)
  "Given context type CXT-TYPE return the context.")
(cl-defmethod sesman-context ((cxt-type (eql buffer)))
  "Return current buffer."
  (current-buffer))
(cl-defmethod sesman-context ((cxt-type (eql directory)))
  "Return current directory."
  default-directory)
(cl-defmethod sesman-context ((cxt-type (eql project)))
  "Return current project."
  (project-current))

(cl-defgeneric sesman-relevant-context-p (cxt-type cxt)
  "Non-nil if context CXT is relevant to current context of type CXT-TYPE.")
(cl-defgeneric sesman-relevant-context-p ((cxt-type (eql buffer)) buf)
  "Non-nil if BUF is `current-buffer'."
  (eq (current-buffer) buf))
(cl-defgeneric sesman-relevant-context-p ((cxt-type (eql directory)) dir)
  "Non-nil if DIR is the parent or equals the `default-directory'."
  (when (and dir default-directory)
    (string-match-p (concat "^" dir) default-directory)))
(cl-defgeneric sesman-relevant-context-p ((cxt-type (eql project)) proj)
  "Non-nil if PROJ is the parent or equals the `default-directory'."
  (when (and proj default-directory)
    (string-match-p (concat "^" (expand-file-name (cdr proj)))
                    default-directory)))


;; Internals

(defun sesman--current-links (&optional system cxt-types)
  (let* ((system (or system (sesman--system)))
         (cxt-types (or cxt-types (sesman-context-types system))))
    (mapcan
     (lambda (cxt-type)
       (let ((lfn (sesman--lookup-fn system nil cxt-type)))
         (sesman--sort-links
          system
          (seq-filter (lambda (l)
                        (and (funcall lfn l)
                             (sesman-relevant-context-p cxt-type (nth 2 l))))
                      sesman-links))))
     cxt-types)))

(defun sesman--link-session (session &optional system cxt-type)
  (let* ((system (or system (sesman--system)))
         (ses-name (or (car-safe session)
                       (error "SESSION must be a headed list")))
         (cxt-type (or cxt-type (car (last (sesman-context-types system)))))
         (cxt-val (sesman-context cxt-type))
         (key (cons system ses-name))
         (link (list key cxt-type cxt-val)))
    (if (member cxt-type sesman-1-to-1-links)
        (thread-last sesman-links
          (seq-remove (sesman--lookup-fn system nil cxt-type cxt-val))
          (cons link)
          (setq sesman-links))
      (unless (seq-filter (sesman--lookup-fn system ses-name cxt-type cxt-val)
                          sesman-links)
        (setq sesman-links (cons link sesman-links))))
    key))

(defun sesman--abrev-maybe (obj)
  (if (stringp obj)
      (abbreviate-file-name obj)
    obj))

(defmacro sesman--link-session-interactively (cxt-type)
  (declare (indent 1)
           (debug (symbolp &rest)))
  (let ((cxt-name (symbol-name cxt-type)))
    `(let ((system (sesman--system)))
       (if (member ',cxt-type (sesman-context-types system))
           (let ((session (sesman--ask-for-session
                           (format "Link with %s %s: "
                                   ,cxt-name (sesman--abrev-maybe
                                              (sesman-context ',cxt-type)))
                           (sesman-sessions)
                           'ask-new)))
             (sesman--link-session session system ',cxt-type))
         (error (format "%s association not allowed for this system (%s)"
                        ,(capitalize (symbol-name cxt-type))
                        (sesman--system)))))))

(defun sesman--system ()
  (if sesman-system
      (if (functionp sesman-system)
          (funcall sesman-system)
        sesman-system)
    (error "No `sesman-system' in buffer `%s'" (current-buffer))))

(defun sesman--lookup-fn (&optional system ses-name cxt-type cxt-val x)
  (let ((system (or system (caar x)))
        (ses-name (or ses-name (cdar x)))
        (cxt-type (or cxt-type (nth 1 x)))
        (cxt-val (or cxt-val (nth 2 x))))
    (lambda (el)
      (and (or (null system) (eq (caar el) system))
           (or (null ses-name) (eq (cdar el) ses-name))
           (or (null cxt-type) (eq (nth 1 el) cxt-type))
           (or (null cxt-val) (equal (nth 2 el) cxt-val))))))

(defun sesman--unlink (x)
  (setq sesman-links
        (seq-remove (sesman--lookup-fn nil nil nil nil x)
                    sesman-links)))

(defun sesman--clear-links ()
  (setq sesman-links
        (seq-filter (lambda (x)
                      (gethash (car x) sesman-sessions))
                    sesman-links)))

(defvar sesman--select-session-history nil)
(defun sesman--ask-for-session (prompt sessions &optional ask-new ask-all)
  (let* ((name.syms (mapcar (lambda (s)
                              (let ((name (car s)))
                                (cons (if (symbolp name) (symbol-name name) name)
                                      name)))
                            sessions))
         (nr (length name.syms))
         (syms (if (and (not ask-new) (= nr 0))
                   (error "No %s sessions found" (sesman--system))
                 (append name.syms
                         (when ask-new '(("*new*")))
                         (when (and ask-all (> nr 1))
                           '(("*all*"))))))
         (def (caar syms))
         ;; (def (if (assoc (car sesman--select-session-history) syms)
         ;;          (car sesman--select-session-history)
         ;;        (caar syms)))
         (sel (completing-read
               prompt (mapcar #'car syms) nil t nil 'sesman--select-session-history def)))
    (cond
     ((string= sel "*new*")
      (let ((ses (sesman-register)))
        (message "Started %s" (car ses))
        (if ask-all (list ses) ses)))
     ((string= sel "*all*")
      sessions)
     (t 
      (let* ((sym (cdr (assoc sel syms)))
             (ses (assoc sym sessions)))
        (if ask-all (list ses) ses))))))

(defun sesman--ask-for-link (prompt links &optional ask-all)
  (let* ((name.keys (mapcar (lambda (x)
                              (let* ((val (nth 2 x))
                                     (val (if (listp val) (cdr val) val)))
                                (cons (format "%s:%s:%s" (cdar x) (nth 1 x) val)
                                      x)))
                            links))
         (name.keys (append name.keys
                            (when (and ask-all (> (length name.keys) 1))
                              '(("*all*")))))
         (nms (mapcar #'car name.keys))
         (sel (completing-read "Unlink: " nms nil t nil nil (car nms))))
    (cond ((string= sel "*all*")
           links)
          (ask-all
           (list (cdr (assoc sel name.keys))))
          (t
           (cdr (assoc sel name.keys))))))

(defun sesman--sort-sessions (system sessions)
  (seq-sort (lambda (x1 x2)
              (sesman-greater-p system x1 x2))
            sessions))

(defun sesman--sort-links (system links)
  (seq-sort (lambda (x1 x2)
              (sesman-greater-p system
                                (gethash (car x1) sesman-sessions)
                                (gethash (car x2) sesman-sessions)))
            links))

(provide 'sesman)
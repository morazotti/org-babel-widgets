;;; org-babel-widgets-test.el --- Tests for org-babel-widgets  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Nícolas André da Costa Morazotti

;; SPDX-License-Identifier: GPL-2.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-babel-widgets)

(defmacro org-babel-widgets-test-with-org (text &rest body)
  "Run BODY in an Org buffer containing TEXT with widgets scanned."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert ,text)
     (let ((org-confirm-babel-evaluate nil)
           (org-babel-load-languages '((emacs-lisp . t))))
       (org-babel-widgets--rescan)
       ,@body)))

(defun org-babel-widgets-test--px (vec w x y) (aref vec (+ (* y w) x)))

;;;; Rasterizer

(ert-deftest org-babel-widgets-test-slider-pixels ()
  (let* ((w 200) (h 20)
         (vec (make-vector (* w h) 0))
         (bg (org-babel-widgets--color 'default :background))
         (track (org-babel-widgets--color 'org-babel-widgets-track :background))
         (accent (org-babel-widgets--color 'org-babel-widgets-accent :background))
         (knob (org-babel-widgets--color 'org-babel-widgets-knob :background)))
    (should-not (= bg track))
    (org-babel-widgets--draw-slider vec w h 0.5 nil)
    (should (= knob (org-babel-widgets-test--px vec w 100 10)))
    (should (= accent (org-babel-widgets-test--px vec w 30 10)))
    (should (= track (org-babel-widgets-test--px vec w 170 10)))
    (should (= bg (org-babel-widgets-test--px vec w 5 0)))
    (org-babel-widgets--draw-slider vec w h 0.0 nil)
    (should (= track (org-babel-widgets-test--px vec w 30 10)))))

(ert-deftest org-babel-widgets-test-toggle-pixels ()
  (let* ((w 36) (h 20)
         (vec (make-vector (* w h) 0))
         (knob (org-babel-widgets--color 'org-babel-widgets-knob :background))
         (accent (org-babel-widgets--color 'org-babel-widgets-accent :background))
         (track (org-babel-widgets--color 'org-babel-widgets-track :background)))
    (org-babel-widgets--draw-toggle vec w h t)
    (should (= knob (org-babel-widgets-test--px vec w (- w 10) 10)))
    (should (= accent (org-babel-widgets-test--px vec w 8 10)))
    (org-babel-widgets--draw-toggle vec w h nil)
    (should (= knob (org-babel-widgets-test--px vec w 10 10)))
    (should (= track (org-babel-widgets-test--px vec w (- w 8) 10)))))

(ert-deftest org-babel-widgets-test-parse-color-hex-widths ()
  (should (equal '(255 0 0) (org-babel-widgets--parse-color "#f00")))
  (should (equal '(18 52 86) (org-babel-widgets--parse-color "#123456")))
  (should (equal '(255 128 0) (org-babel-widgets--parse-color "#ffff80000000")))
  (should-not (org-babel-widgets--parse-color "unspecified-bg")))

;;;; Model

(ert-deftest org-babel-widgets-test-parse-slider-defaults-and-snap ()
  (let ((w (org-babel-widgets--parse-line "a" "slider" ":min 0 :max 10 :step 0.25 :value 3.1")))
    (should (= 3.0 (org-babel-widgets-widget-value w)))
    (should (= 10 (org-babel-widgets--snap w 99)))
    (should (= 0 (org-babel-widgets--snap w -5)))
    (should (= 0.3 (org-babel-widgets--snap (org-babel-widgets--parse-line "b" "slider" ":min 0 :max 1 :step 0.1") 0.3000000001)))))

(ert-deftest org-babel-widgets-test-x->value-extremes ()
  (let* ((w (org-babel-widgets--parse-line "a" "slider" ":min 0 :max 10 :step 1"))
         (width org-babel-widgets-slider-width))
    (should (= 0 (org-babel-widgets--x->value w 0)))
    (should (= 10 (org-babel-widgets--x->value w width)))
    (should (= 5 (org-babel-widgets--x->value w (/ width 2))))))

(ert-deftest org-babel-widgets-test-parse-choice ()
  (let ((w (org-babel-widgets--parse-line "s" "choice" ":options (\"-\" \"--\") :value \"--\"")))
    (should (equal "--" (org-babel-widgets-widget-value w)))
    (should (equal '("-" "--") (org-babel-widgets-widget-options w)))))

(ert-deftest org-babel-widgets-test-parse-errors-have-org-babel-widgets-prefix ()
  (dolist (case '(("x" "slider" ":min 5 :max 1")
                  ("x" "slider" ":step 0")
                  ("x" "wat" "")
                  ("x" "choice" "")
                  ("x" "choice" ":options (\"a\") :value \"b\"")
                  ("x" "slider" ":bogus 1")
                  ("x" "slider" ":min (")))
    (let ((err (should-error (apply #'org-babel-widgets--parse-line case) :type 'user-error)))
      (should (string-prefix-p "Widget error: " (cadr err))))))

(ert-deftest org-babel-widgets-test-value-set-semantics ()
  (org-babel-widgets-test-with-org "#+WIDGET: a slider :min 0 :max 10 :step 1 :value 2
#+WIDGET: t toggle
#+WIDGET: c choice :options (\"x\" \"y\")
#+WIDGET: b button
"
    (should (= 2 (org-babel-widgets-value "a")))
    (should (= 7 (org-babel-widgets-set "a" 6.6)))
    (should (= 0 (org-babel-widgets-value "t")))
    (should (= 1 (org-babel-widgets-set "t" t)))
    (should (= 0 (org-babel-widgets-set "t" 0)))
    (should (equal "y" (org-babel-widgets-set "c" "y")))
    (should-error (org-babel-widgets-set "c" "z") :type 'user-error)
    (should (= 0 (org-babel-widgets-value "b")))
    (should (= 2 (progn (org-babel-widgets-set "b" nil) (org-babel-widgets-set "b" nil))))
    (should-error (org-babel-widgets-value "nope") :type 'error)))

(ert-deftest org-babel-widgets-test-step-keyboard-semantics ()
  (org-babel-widgets-test-with-org "#+WIDGET: a slider :min 0 :max 10 :step 1 :value 5
#+WIDGET: c choice :options (\"x\" \"y\" \"z\")
"
    (org-babel-widgets--step (org-babel-widgets--lookup "a") 10)
    (should (= 10 (org-babel-widgets-value "a")))
    (org-babel-widgets--step (org-babel-widgets--lookup "c") -1)
    (should (equal "z" (org-babel-widgets-value "c")))
    (org-babel-widgets--step (org-babel-widgets--lookup "c") 1)
    (should (equal "x" (org-babel-widgets-value "c")))))

(ert-deftest org-babel-widgets-test-pointer-set ()
  (org-babel-widgets-test-with-org "#+WIDGET: a slider :min 0 :max 100 :step 1\n"
    (org-babel-widgets--pointer-set (org-babel-widgets--lookup "a") (/ org-babel-widgets-slider-width 2))
    (should (= 50 (org-babel-widgets-value "a")))))

;;;; Rescan

(ert-deftest org-babel-widgets-test-rescan-errors-and-state ()
  (org-babel-widgets-test-with-org "#+WIDGET: a slider :min 0 :max 10 :step 1 :value 2
#+WIDGET: a toggle
#+WIDGET: bad slider :min 5 :max 1
"
    (let ((msgs (mapcar (lambda (o) (substring-no-properties (overlay-get o 'before-string)))
                        (cl-remove-if-not (lambda (o) (and (overlay-get o 'cw)
                                                           (not (overlay-get o 'keymap))))
                                          (overlays-in (point-min) (point-max))))))
      (should (cl-some (lambda (m) (string-prefix-p "Widget error: duplicate widget a" m)) msgs))
      (should (cl-some (lambda (m) (string-prefix-p "Widget error: :min must be less" m)) msgs)))
    (should-error (org-babel-widgets-value "bad") :type 'error)
    ;; Unchanged line keeps state; edited line preserves value when type matches.
    (org-babel-widgets-set "a" 7)
    (org-babel-widgets--rescan)
    (should (= 7 (org-babel-widgets-value "a")))
    (goto-char (point-min))
    (search-forward ":max 10")
    (replace-match ":max 20")
    (org-babel-widgets--rescan)
    (should (= 7 (org-babel-widgets-value "a")))
    (should (= 20 (org-babel-widgets-widget-max (org-babel-widgets--lookup "a"))))
    ;; Deleting the first line promotes the duplicate declaration.
    (goto-char (point-min))
    (delete-region (point) (progn (forward-line 1) (point)))
    (org-babel-widgets--rescan)
    (should (eq 'toggle (org-babel-widgets-widget-type (org-babel-widgets--lookup "a"))))))

;;;; Babel bridge

(defconst org-babel-widgets-test--doc
  "#+WIDGET: a slider :min 0 :max 10 :step 1 :value 2
#+WIDGET: b toggle

#+begin_src emacs-lisp :var a=(org-babel-widgets-value \"a\")
(* 2 a)
#+end_src

#+begin_src emacs-lisp :var b=(org-babel-widgets-value \"b\")
(+ 100 b)
#+end_src

#+begin_src emacs-lisp :var a=(org-babel-widgets-value \"a\") :var b=(org-babel-widgets-value \"b\")
(list a b)
#+end_src
")

(defun org-babel-widgets-test--result-after (n)
  "Return the text of the #+RESULTS: following the Nth source block, or nil."
  (save-excursion
    (goto-char (point-min))
    (dotimes (_ n) (re-search-forward "^#\\+end_src"))
    (forward-line 1)
    (skip-chars-forward " \t\n")
    (beginning-of-line)
    (when (looking-at "^#\\+RESULTS:")
      (buffer-substring-no-properties (point) (org-babel-result-end)))))

(ert-deftest org-babel-widgets-test-dependent-blocks-order ()
  (org-babel-widgets-test-with-org org-babel-widgets-test--doc
    (let ((ms (org-babel-widgets--dependent-blocks '("a"))))
      (unwind-protect
          (should (equal '(4 12) (mapcar (lambda (m) (line-number-at-pos m)) ms)))
        (mapc (lambda (m) (set-marker m nil)) ms)))
    (should-not (org-babel-widgets--dependent-blocks nil))))

(ert-deftest org-babel-widgets-test-flush-reruns-only-dependents ()
  (org-babel-widgets-test-with-org org-babel-widgets-test--doc
    (org-babel-widgets-set "a" 5)
    (org-babel-widgets--flush (current-buffer))
    (should (string-match-p "\\b10\\b" (org-babel-widgets-test--result-after 1)))
    (should-not (org-babel-widgets-test--result-after 2))
    (should (string-match-p "5 | 0" (org-babel-widgets-test--result-after 3)))))

(ert-deftest org-babel-widgets-test-flush-reruns-when-block-changes-widget ()
  (org-babel-widgets-test-with-org org-babel-widgets-test--doc
    (let ((orig (symbol-function 'org-babel-execute-src-block))
          (first t))
      (cl-letf (((symbol-function 'org-babel-execute-src-block)
                 (lambda (&rest args)
                   (when first (setq first nil) (org-babel-widgets-set "b" t))
                   (apply orig args))))
        (org-babel-widgets-set "a" 4)
        (org-babel-widgets--flush (current-buffer))
        (should-not org-babel-widgets--running)
        (should org-babel-widgets--pending)
        (org-babel-widgets--flush (current-buffer))
        (should (string-match-p "101" (org-babel-widgets-test--result-after 2)))
        (should-not org-babel-widgets--pending)))))

(ert-deftest org-babel-widgets-test-flush-survives-block-error ()
  (org-babel-widgets-test-with-org org-babel-widgets-test--doc
    (let ((orig (symbol-function 'org-babel-execute-src-block))
          (calls 0))
      (cl-letf (((symbol-function 'org-babel-execute-src-block)
                 (lambda (&rest args)
                   (when (= 1 (cl-incf calls)) (error "boom"))
                   (apply orig args))))
        (org-babel-widgets-set "a" 3)
        (org-babel-widgets--flush (current-buffer))
        (should (= 2 calls))
        (should-not org-babel-widgets--running)
        (should (string-match-p "3 | 0" (org-babel-widgets-test--result-after 3)))))))


(ert-deftest org-babel-widgets-test-continuous-slider-does-not-snap ()
  (let ((w (org-babel-widgets--parse-line "c" "slider" ":min 0 :max 1 :continuous t :step 1")))
    (should (= 0.1234 (org-babel-widgets--snap w 0.1234)))
    (should (= 1 (org-babel-widgets--snap w 7)))
    (let ((px (org-babel-widgets--x->value w 77)))
      (should (floatp px))
      (should-not (= px (* 0.01 (round (* 100 px))))))
    (should (equal "0.1234" (progn (setf (org-babel-widgets-widget-value w) 0.1234) (org-babel-widgets--value-text w)))))
  (let ((w (org-babel-widgets--parse-line "d" "slider" ":min 0 :max 10 :continuous t")))
    (should (= 0.1 (org-babel-widgets-widget-step w)))))
;;; org-babel-widgets-test.el ends here

;;; canvas-widgets-test.el --- Tests for canvas-widgets  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'canvas-widgets)

(defmacro cw-test-with-org (text &rest body)
  "Run BODY in an Org buffer containing TEXT with widgets scanned."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert ,text)
     (let ((org-confirm-babel-evaluate nil)
           (org-babel-load-languages '((emacs-lisp . t))))
       (cw--rescan)
       ,@body)))

(defun cw-test--px (vec w x y) (aref vec (+ (* y w) x)))

;;;; Rasterizer

(ert-deftest cw-test-slider-pixels ()
  (let* ((w 200) (h 20)
         (vec (make-vector (* w h) 0))
         (bg (cw--color 'default :background))
         (track (cw--color 'cw-track :background))
         (accent (cw--color 'cw-accent :background))
         (knob (cw--color 'cw-knob :background)))
    (should-not (= bg track))
    (cw--draw-slider vec w h 0.5 nil)
    (should (= knob (cw-test--px vec w 100 10)))
    (should (= accent (cw-test--px vec w 30 10)))
    (should (= track (cw-test--px vec w 170 10)))
    (should (= bg (cw-test--px vec w 5 0)))
    (cw--draw-slider vec w h 0.0 nil)
    (should (= track (cw-test--px vec w 30 10)))))

(ert-deftest cw-test-toggle-pixels ()
  (let* ((w 36) (h 20)
         (vec (make-vector (* w h) 0))
         (knob (cw--color 'cw-knob :background))
         (accent (cw--color 'cw-accent :background))
         (track (cw--color 'cw-track :background)))
    (cw--draw-toggle vec w h t)
    (should (= knob (cw-test--px vec w (- w 10) 10)))
    (should (= accent (cw-test--px vec w 8 10)))
    (cw--draw-toggle vec w h nil)
    (should (= knob (cw-test--px vec w 10 10)))
    (should (= track (cw-test--px vec w (- w 8) 10)))))

(ert-deftest cw-test-parse-color-hex-widths ()
  (should (equal '(255 0 0) (cw--parse-color "#f00")))
  (should (equal '(18 52 86) (cw--parse-color "#123456")))
  (should (equal '(255 128 0) (cw--parse-color "#ffff80000000")))
  (should-not (cw--parse-color "unspecified-bg")))

;;;; Model

(ert-deftest cw-test-parse-slider-defaults-and-snap ()
  (let ((w (cw--parse-line "a" "slider" ":min 0 :max 10 :step 0.25 :value 3.1")))
    (should (= 3.0 (cw-widget-value w)))
    (should (= 10 (cw--snap w 99)))
    (should (= 0 (cw--snap w -5)))
    (should (= 0.3 (cw--snap (cw--parse-line "b" "slider" ":min 0 :max 1 :step 0.1") 0.3000000001)))))

(ert-deftest cw-test-x->value-extremes ()
  (let* ((w (cw--parse-line "a" "slider" ":min 0 :max 10 :step 1"))
         (width cw-slider-width))
    (should (= 0 (cw--x->value w 0)))
    (should (= 10 (cw--x->value w width)))
    (should (= 5 (cw--x->value w (/ width 2))))))

(ert-deftest cw-test-parse-choice ()
  (let ((w (cw--parse-line "s" "choice" ":options (\"-\" \"--\") :value \"--\"")))
    (should (equal "--" (cw-widget-value w)))
    (should (equal '("-" "--") (cw-widget-options w)))))

(ert-deftest cw-test-parse-errors-have-cw-prefix ()
  (dolist (case '(("x" "slider" ":min 5 :max 1")
                  ("x" "slider" ":step 0")
                  ("x" "wat" "")
                  ("x" "choice" "")
                  ("x" "choice" ":options (\"a\") :value \"b\"")
                  ("x" "slider" ":bogus 1")
                  ("x" "slider" ":min (")))
    (let ((err (should-error (apply #'cw--parse-line case) :type 'user-error)))
      (should (string-prefix-p "cw: " (cadr err))))))

(ert-deftest cw-test-value-set-semantics ()
  (cw-test-with-org "#+WIDGET: a slider :min 0 :max 10 :step 1 :value 2
#+WIDGET: t toggle
#+WIDGET: c choice :options (\"x\" \"y\")
#+WIDGET: b button
"
    (should (= 2 (cw-value "a")))
    (should (= 7 (cw-set "a" 6.6)))
    (should (= 0 (cw-value "t")))
    (should (= 1 (cw-set "t" t)))
    (should (= 0 (cw-set "t" 0)))
    (should (equal "y" (cw-set "c" "y")))
    (should-error (cw-set "c" "z") :type 'user-error)
    (should (= 0 (cw-value "b")))
    (should (= 2 (progn (cw-set "b" nil) (cw-set "b" nil))))
    (should-error (cw-value "nope") :type 'error)))

(ert-deftest cw-test-step-keyboard-semantics ()
  (cw-test-with-org "#+WIDGET: a slider :min 0 :max 10 :step 1 :value 5
#+WIDGET: c choice :options (\"x\" \"y\" \"z\")
"
    (cw--step (cw--lookup "a") 10)
    (should (= 10 (cw-value "a")))
    (cw--step (cw--lookup "c") -1)
    (should (equal "z" (cw-value "c")))
    (cw--step (cw--lookup "c") 1)
    (should (equal "x" (cw-value "c")))))

(ert-deftest cw-test-pointer-set ()
  (cw-test-with-org "#+WIDGET: a slider :min 0 :max 100 :step 1\n"
    (cw--pointer-set (cw--lookup "a") (/ cw-slider-width 2))
    (should (= 50 (cw-value "a")))))

;;;; Rescan

(ert-deftest cw-test-rescan-errors-and-state ()
  (cw-test-with-org "#+WIDGET: a slider :min 0 :max 10 :step 1 :value 2
#+WIDGET: a toggle
#+WIDGET: bad slider :min 5 :max 1
"
    (let ((msgs (mapcar (lambda (o) (substring-no-properties (overlay-get o 'before-string)))
                        (cl-remove-if-not (lambda (o) (and (overlay-get o 'cw)
                                                           (not (overlay-get o 'keymap))))
                                          (overlays-in (point-min) (point-max))))))
      (should (cl-some (lambda (m) (string-prefix-p "cw: duplicate widget a" m)) msgs))
      (should (cl-some (lambda (m) (string-prefix-p "cw: :min must be less" m)) msgs)))
    (should-error (cw-value "bad") :type 'error)
    ;; Unchanged line keeps state; edited line preserves value when type matches.
    (cw-set "a" 7)
    (cw--rescan)
    (should (= 7 (cw-value "a")))
    (goto-char (point-min))
    (search-forward ":max 10")
    (replace-match ":max 20")
    (cw--rescan)
    (should (= 7 (cw-value "a")))
    (should (= 20 (cw-widget-max (cw--lookup "a"))))
    ;; Deleting the first line promotes the duplicate declaration.
    (goto-char (point-min))
    (delete-region (point) (progn (forward-line 1) (point)))
    (cw--rescan)
    (should (eq 'toggle (cw-widget-type (cw--lookup "a"))))))

;;;; Babel bridge

(defconst cw-test--doc
  "#+WIDGET: a slider :min 0 :max 10 :step 1 :value 2
#+WIDGET: b toggle

#+begin_src emacs-lisp :var a=(cw-value \"a\")
(* 2 a)
#+end_src

#+begin_src emacs-lisp :var b=(cw-value \"b\")
(+ 100 b)
#+end_src

#+begin_src emacs-lisp :var a=(cw-value \"a\") :var b=(cw-value \"b\")
(list a b)
#+end_src
")

(defun cw-test--result-after (n)
  "Return the text of the #+RESULTS: following the Nth source block, or nil."
  (save-excursion
    (goto-char (point-min))
    (dotimes (_ n) (re-search-forward "^#\\+end_src"))
    (forward-line 1)
    (skip-chars-forward " \t\n")
    (beginning-of-line)
    (when (looking-at "^#\\+RESULTS:")
      (buffer-substring-no-properties (point) (org-babel-result-end)))))

(ert-deftest cw-test-dependent-blocks-order ()
  (cw-test-with-org cw-test--doc
    (let ((ms (cw--dependent-blocks '("a"))))
      (unwind-protect
          (should (equal '(4 12) (mapcar (lambda (m) (line-number-at-pos m)) ms)))
        (mapc (lambda (m) (set-marker m nil)) ms)))
    (should-not (cw--dependent-blocks nil))))

(ert-deftest cw-test-flush-reruns-only-dependents ()
  (cw-test-with-org cw-test--doc
    (cw-set "a" 5)
    (cw--flush (current-buffer))
    (should (string-match-p "\\b10\\b" (cw-test--result-after 1)))
    (should-not (cw-test--result-after 2))
    (should (string-match-p "5 | 0" (cw-test--result-after 3)))))

(ert-deftest cw-test-flush-reruns-when-block-changes-widget ()
  (cw-test-with-org cw-test--doc
    (let ((orig (symbol-function 'org-babel-execute-src-block))
          (first t))
      (cl-letf (((symbol-function 'org-babel-execute-src-block)
                 (lambda (&rest args)
                   (when first (setq first nil) (cw-set "b" t))
                   (apply orig args))))
        (cw-set "a" 4)
        (cw--flush (current-buffer))
        (should-not cw--running)
        (should cw--pending)
        (cw--flush (current-buffer))
        (should (string-match-p "101" (cw-test--result-after 2)))
        (should-not cw--pending)))))

(ert-deftest cw-test-flush-survives-block-error ()
  (cw-test-with-org cw-test--doc
    (let ((orig (symbol-function 'org-babel-execute-src-block))
          (calls 0))
      (cl-letf (((symbol-function 'org-babel-execute-src-block)
                 (lambda (&rest args)
                   (when (= 1 (cl-incf calls)) (error "boom"))
                   (apply orig args))))
        (cw-set "a" 3)
        (cw--flush (current-buffer))
        (should (= 2 calls))
        (should-not cw--running)
        (should (string-match-p "3 | 0" (cw-test--result-after 3)))))))

;;; canvas-widgets-test.el ends here

(ert-deftest cw-test-continuous-slider-does-not-snap ()
  (let ((w (cw--parse-line "c" "slider" ":min 0 :max 1 :continuous t :step 1")))
    (should (= 0.1234 (cw--snap w 0.1234)))
    (should (= 1 (cw--snap w 7)))
    (let ((px (cw--x->value w 77)))
      (should (floatp px))
      (should-not (= px (* 0.01 (round (* 100 px))))))
    (should (equal "0.1234" (progn (setf (cw-widget-value w) 0.1234) (cw--value-text w)))))
  (let ((w (cw--parse-line "d" "slider" ":min 0 :max 10 :continuous t")))
    (should (= 0.1 (cw-widget-step w)))))

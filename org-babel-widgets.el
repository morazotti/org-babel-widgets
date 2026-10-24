;;; org-babel-widgets.el --- Interactive canvas widgets for Org Babel  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 morazotti

;; Author: morazotti <nicolas.morazotti@gmail.com>
;; Maintainer: morazotti <nicolas.morazotti@gmail.com>
;; URL: https://github.com/morazotti/org-babel-widgets
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0") (org "9.8"))
;; Keywords: outlines, tools
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

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
;; 02110-1301, USA.

;;; Commentary:

;; Sliders, buttons, toggles and choice menus drawn on Emacs 32 `canvas'
;; images.  Declare a widget in an Org buffer with
;;
;;   #+WIDGET: NAME TYPE [:min N] [:max N] [:step N] [:value V]
;;                       [:options ("a" "b")] [:label "text"]
;;
;; TYPE is one of `slider', `button', `toggle' or `choice'.  Reference the
;; current value from any Babel block header with
;;
;;   #+begin_src python :var amp=(org-babel-widgets-value "NAME")
;;
;; Whenever the widget changes, every block whose #+begin_src line
;; references it is re-executed (debounced) and its image results are
;; refreshed, similar to `ipywidgets.interact'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'ob-core)

(defgroup org-babel-widgets nil
  "Interactive canvas widgets for Org Babel."
  :group 'org-babel
  :prefix "org-babel-widgets-")

(defcustom org-babel-widgets-height 20
  "Height in pixels of every widget canvas."
  :type 'natnum)

(defcustom org-babel-widgets-slider-width 200
  "Width in pixels of slider canvases."
  :type 'natnum)

(defcustom org-babel-widgets-debounce 0.12
  "Seconds to wait after the last widget change before re-running blocks."
  :type 'number)

(defface org-babel-widgets-track
  '((((background dark)) :background "#555a66")
    (t :background "#c4c8d0"))
  "Background color of unfilled widget parts."
  :group 'org-babel-widgets)

(defface org-babel-widgets-accent
  '((((background dark)) :background "#6ea8fe")
    (t :background "#2f6fe0"))
  "Background color of active widget parts."
  :group 'org-babel-widgets)

(defface org-babel-widgets-knob
  '((((background dark)) :background "#f0f2f5")
    (t :background "#ffffff"))
  "Background color of knobs and glyphs."
  :group 'org-babel-widgets)

;;;; Rasterizer

(defun org-babel-widgets--parse-color (str)
  "Return STR as a list (R G B) of 0..255 integers, or nil if unusable."
  (cond
   ((not (stringp str)) nil)
   ((string-match "\\`#\\([[:xdigit:]]+\\)\\'" str)
    (let* ((hex (match-string 1 str))
           (n (length hex)))
      (when (zerop (% n 3))
        (let* ((d (/ n 3))
               (mx (float (1- (expt 16 d)))))
          (mapcar (lambda (i)
                    (round (* 255 (/ (string-to-number
                                      (substring hex (* i d) (* (1+ i) d)) 16)
                                     mx))))
                  '(0 1 2))))))
   ((string-prefix-p "unspecified" str) nil)
   (t (when-let* ((v (color-values str)))
        (mapcar (lambda (c) (/ c 257)) v)))))

(defun org-babel-widgets--color (face attr)
  "Return ATTR of FACE as opaque ARGB32 integer.
Falls back to the `default' face when FACE does not set ATTR."
  (pcase-let* ((`(,r ,g ,b)
                (or (org-babel-widgets--parse-color (face-attribute face attr nil 'default))
                    (org-babel-widgets--parse-color (face-attribute 'default attr))
                    (if (eq attr :foreground) '(255 255 255) '(0 0 0)))))
    (logior #xFF000000 (ash r 16) (ash g 8) b)))

(defun org-babel-widgets--blend (dst src alpha)
  "Blend ARGB32 SRC over DST with coverage ALPHA (0.0-1.0); result is opaque."
  (let ((out 0))
    (dolist (sh '(16 8 0))
      (let ((d (logand (ash dst (- sh)) 255))
            (s (logand (ash src (- sh)) 255)))
        (setq out (logior out (ash (round (+ (* d (- 1.0 alpha)) (* s alpha)))
                                   sh)))))
    (logior #xFF000000 out)))

(defun org-babel-widgets--plot (vec w x y color coverage)
  "Blend COLOR with COVERAGE into pixel (X, Y) of VEC (row width W)."
  (when (> coverage 0.0)
    (let ((i (+ (* y w) x)))
      (aset vec i (if (>= coverage 0.999)
                      color
                    (org-babel-widgets--blend (aref vec i) color coverage))))))

(defun org-babel-widgets--fill-circle (vec w cx cy r color)
  "Draw an antialiased filled circle in VEC (row width W).
The circle is centered (CX, CY) with radius R and filled with COLOR."
  (let ((h (/ (length vec) w)))
    (cl-loop for y from (max 0 (floor (- cy r 1))) to (min (1- h) (ceiling (+ cy r 1)))
             do (cl-loop for x from (max 0 (floor (- cx r 1))) to (min (1- w) (ceiling (+ cx r 1)))
                         do (let* ((dx (- (+ x 0.5) cx))
                                   (dy (- (+ y 0.5) cy))
                                   (d (- (sqrt (+ (* dx dx) (* dy dy))) r)))
                              (org-babel-widgets--plot vec w x y color (min 1.0 (- 0.5 d))))))))

(defun org-babel-widgets--fill-rrect (vec w x y width height r color)
  "Draw an antialiased filled rounded rectangle in VEC (row width W).
Top-left corner (X, Y), size WIDTH x HEIGHT, corner radius R, fill COLOR."
  (let* ((h (/ (length vec) w))
         (hw (/ width 2.0))
         (hh (/ height 2.0))
         (r (min r hw hh))
         (cx (+ x hw))
         (cy (+ y hh)))
    (cl-loop for py from (max 0 (floor (- y 1))) to (min (1- h) (ceiling (+ y height 1)))
             do (cl-loop for px from (max 0 (floor (- x 1))) to (min (1- w) (ceiling (+ x width 1)))
                         do (let* ((qx (- (abs (- (+ px 0.5) cx)) (- hw r)))
                                   (qy (- (abs (- (+ py 0.5) cy)) (- hh r)))
                                   (ox (max qx 0.0))
                                   (oy (max qy 0.0))
                                   (d (- (+ (sqrt (+ (* ox ox) (* oy oy)))
                                            (min (max qx qy) 0.0))
                                         r)))
                              (org-babel-widgets--plot vec w px py color (min 1.0 (- 0.5 d))))))))

(defun org-babel-widgets--draw-slider (vec w h frac pressed)
  "Redraw slider into VEC (W x H) with fill fraction FRAC (0.0-1.0).
PRESSED draws the knob in its pressed state."
  (let* ((pad (/ h 2))
         (len (- w (* 2 pad)))
         (cx (+ pad (* frac len)))
         (cy (/ h 2.0))
         (ty (/ (- h 4) 2.0))
         (track (org-babel-widgets--color 'org-babel-widgets-track :background))
         (accent (org-babel-widgets--color 'org-babel-widgets-accent :background))
         (knob (org-babel-widgets--color 'org-babel-widgets-knob :background)))
    (fillarray vec (org-babel-widgets--color 'default :background))
    (org-babel-widgets--fill-rrect vec w pad ty len 4 2 track)
    (when (>= (- cx pad) 1)
      (org-babel-widgets--fill-rrect vec w pad ty (- cx pad) 4 2 accent))
    (org-babel-widgets--fill-circle vec w cx cy (- cy 2) accent)
    (org-babel-widgets--fill-circle vec w cx cy (- cy 4) (if pressed accent knob))))

(defun org-babel-widgets--draw-button (vec w h pressed)
  "Redraw button into VEC (W x H); PRESSED draws the pressed state."
  (fillarray vec (org-babel-widgets--color 'default :background))
  (org-babel-widgets--fill-rrect vec w 1 1 (- w 2) (- h 2) 4
                  (org-babel-widgets--color (if pressed 'org-babel-widgets-accent 'org-babel-widgets-track) :background))
  (org-babel-widgets--fill-circle vec w (/ w 2.0) (/ h 2.0) (- (/ h 2.0) 6)
                   (org-babel-widgets--color 'org-babel-widgets-knob :background)))

(defun org-babel-widgets--draw-toggle (vec w h on)
  "Redraw toggle into VEC (W x H); ON non-nil draws the active state."
  (fillarray vec (org-babel-widgets--color 'default :background))
  (org-babel-widgets--fill-rrect vec w 2 2 (- w 4) (- h 4) (- (/ h 2.0) 2)
                  (org-babel-widgets--color (if on 'org-babel-widgets-accent 'org-babel-widgets-track) :background))
  (org-babel-widgets--fill-circle vec w (if on (- w (/ h 2.0)) (/ h 2.0)) (/ h 2.0)
                   (- (/ h 2.0) 5) (org-babel-widgets--color 'org-babel-widgets-knob :background)))

(defun org-babel-widgets--draw-choice (vec w h pressed)
  "Redraw choice button into VEC (W x H); PRESSED draws the pressed state."
  (let ((cx (/ w 2.0))
        (cy (/ h 2.0))
        (knob (org-babel-widgets--color 'org-babel-widgets-knob :background)))
    (fillarray vec (org-babel-widgets--color 'default :background))
    (org-babel-widgets--fill-rrect vec w 1 1 (- w 2) (- h 2) 4
                    (org-babel-widgets--color (if pressed 'org-babel-widgets-accent 'org-babel-widgets-track) :background))
    (org-babel-widgets--fill-circle vec w (- cx 3) (- cy 1) 1.2 knob)
    (org-babel-widgets--fill-circle vec w cx (+ cy 2) 1.2 knob)
    (org-babel-widgets--fill-circle vec w (+ cx 3) (- cy 1) 1.2 knob)))

;;;; Model

(cl-defstruct org-babel-widgets-widget
  name type value min max step options label canvas overlay spec pressed continuous)

(defvar-local org-babel-widgets--widgets nil
  "Hash table mapping widget names to widget structs in this buffer.")

(defvar-local org-babel-widgets--pending nil
  "Names of widgets changed since the last block re-execution.")

(defvar-local org-babel-widgets--timer nil
  "Pending debounce timer for `org-babel-widgets--flush'.")

(defvar-local org-babel-widgets--running nil
  "Non-nil while `org-babel-widgets--flush' is executing blocks.")

(defvar-local org-babel-widgets--rescan-timer nil
  "Idle timer scheduled by `org-babel-widgets--after-change'.")

(defvar org-babel-widgets-mode)

(defconst org-babel-widgets--types '(slider button toggle choice))

(defconst org-babel-widgets--line-re
  (rx bol "#+WIDGET:" (* (any " \t"))
      (group (* (not (any " \t\n")))) (* (any " \t"))
      (group (* (not (any " \t\n")))) (* (any " \t"))
      (group (* nonl)) eol)
  "Match a widget declaration: groups are NAME, TYPE and the option text.")

(defun org-babel-widgets--table ()
  "Return this buffer's widget table, creating it if needed."
  (or org-babel-widgets--widgets (setq org-babel-widgets--widgets (make-hash-table :test #'equal))))

(defun org-babel-widgets--clean (w v)
  "Remove float noise from V according to the number format of slider W."
  (if (and (integerp (org-babel-widgets-widget-min w)) (integerp (org-babel-widgets-widget-step w))
           (not (org-babel-widgets-widget-continuous w)))
      (round v)
    (string-to-number (format "%.10g" v))))

(defun org-babel-widgets--snap (w raw)
  "Clamp RAW to slider W's range; snap to its step unless W is continuous."
  (let* ((mn (org-babel-widgets-widget-min w))
         (mx (org-babel-widgets-widget-max w))
         (clamped (max mn (min mx raw))))
    (if (org-babel-widgets-widget-continuous w)
        (org-babel-widgets--clean w clamped)
      (let* ((n (round (/ (- clamped mn) (float (org-babel-widgets-widget-step w)))))
             (v (+ mn (* (org-babel-widgets-widget-step w) n))))
        (org-babel-widgets--clean w (max mn (min mx v)))))))

(defun org-babel-widgets--canvas-width (w)
  "Return the pixel width of widget W's canvas."
  (plist-get (cdr (org-babel-widgets-widget-canvas w)) :data-width))

(defun org-babel-widgets--x->value (w x)
  "Return slider W's value for pixel X relative to the left of its canvas."
  (let* ((width (org-babel-widgets--canvas-width w))
         (pad (/ org-babel-widgets-height 2))
         (frac (max 0.0 (min 1.0 (/ (- x pad) (float (- width (* 2 pad))))))))
    (org-babel-widgets--snap w (+ (org-babel-widgets-widget-min w)
                   (* frac (- (org-babel-widgets-widget-max w) (org-babel-widgets-widget-min w)))))))

(defun org-babel-widgets--new-canvas (type)
  "Return a fresh canvas image spec sized for widget TYPE."
  (let ((width (pcase type
                 ('slider org-babel-widgets-slider-width)
                 ('button 32)
                 ('toggle 36)
                 ('choice 24))))
    (create-image (make-vector (* width org-babel-widgets-height) 0) 'canvas t
                  :data-width width :data-height org-babel-widgets-height)))

(defun org-babel-widgets--parse-line (name type rest)
  "Return a `org-babel-widgets-widget' for NAME, TYPE and the option text REST.
Signal `user-error' with a \"Widget error: \" message on invalid input."
  (when (string-empty-p name) (user-error "Widget error: missing widget name"))
  (let ((sym (and (not (string-empty-p type)) (intern type)))
        plist)
    (unless (memq sym org-babel-widgets--types)
      (user-error "Widget error: unknown widget type %S (want slider, button, toggle or choice)" type))
    (setq plist
          (condition-case err
              (car (read-from-string (concat "(" rest ")")))
            (error (user-error "Widget error: cannot read options %S: %s" rest
                               (error-message-string err)))))
    (unless (and (proper-list-p plist) (cl-evenp (length plist)))
      (user-error "Widget error: options must be :key value pairs"))
    (cl-loop for (k _v) on plist by #'cddr
             unless (memq k '(:min :max :step :value :label :options :continuous))
             do (user-error "Widget error: unknown option %S" k))
    (let* ((w (make-org-babel-widgets-widget :name name :type sym :spec nil
                              :label (or (plist-get plist :label) name)
                              :canvas (org-babel-widgets--new-canvas sym)))
           (value (plist-get plist :value)))
      (pcase sym
        ('slider
         (let* ((mn (if (plist-member plist :min) (plist-get plist :min) 0))
               (mx (if (plist-member plist :max) (plist-get plist :max) 1))
               (st (cond ((plist-member plist :step) (plist-get plist :step))
                         ((plist-get plist :continuous)
                          (let ((lo (if (numberp mn) mn 0)) (hi (if (numberp mx) mx 1)))
                            (/ (- hi lo) 100.0)))
                         (t 0.01))))
           (unless (and (numberp mn) (numberp mx) (numberp st))
             (user-error "Widget error: :min, :max and :step must be numbers"))
           (unless (< mn mx) (user-error "Widget error: :min must be less than :max"))
           (unless (> st 0) (user-error "Widget error: :step must be positive"))
           (unless (or (null value) (numberp value))
             (user-error "Widget error: :value must be a number"))
           (setf (org-babel-widgets-widget-min w) mn (org-babel-widgets-widget-max w) mx (org-babel-widgets-widget-step w) st
                 (org-babel-widgets-widget-continuous w) (and (plist-get plist :continuous) t))
           (setf (org-babel-widgets-widget-value w) (org-babel-widgets--snap w (or value mn)))))
        ('toggle (setf (org-babel-widgets-widget-value w) (and value t)))
        ('button (setf (org-babel-widgets-widget-value w) 0))
        ('choice
         (let ((opts (plist-get plist :options)))
           (unless (and (consp opts) (proper-list-p opts) (cl-every #'stringp opts))
             (user-error "Widget error: choice needs :options as a list of strings"))
           (when (and value (not (member value opts)))
             (user-error "Widget error: :value %S is not in :options" value))
           (setf (org-babel-widgets-widget-options w) opts
                 (org-babel-widgets-widget-value w) (or value (car opts))))))
      w)))

(defun org-babel-widgets--lookup (name)
  "Return the widget called NAME in the current buffer or signal an error."
  (or (gethash name (org-babel-widgets--table))
      (error "Widget error: no widget named %S in this buffer" name)))

(defun org-babel-widgets-value (name)
  "Return the current value of widget NAME in the current buffer.
Sliders give a number, toggles 1 or 0, buttons their click count and
choices the selected string."
  (let ((w (org-babel-widgets--lookup name)))
    (pcase (org-babel-widgets-widget-type w)
      ('toggle (if (org-babel-widgets-widget-value w) 1 0))
      (_ (org-babel-widgets-widget-value w)))))

(defun org-babel-widgets--set-widget (w value)
  "Set widget W to VALUE and return non-nil if its value changed.
A change redraws W and schedules dependent blocks."
  (let* ((old (org-babel-widgets-widget-value w))
         (new (pcase (org-babel-widgets-widget-type w)
                ('slider (org-babel-widgets--snap w value))
                ('toggle (and value (not (eql value 0)) t))
                ('button (1+ old))
                ('choice (if (member value (org-babel-widgets-widget-options w))
                             value
                           (user-error "Widget error: %S is not one of %S" value
                                       (org-babel-widgets-widget-options w)))))))
    (unless (equal old new)
      (setf (org-babel-widgets-widget-value w) new)
      (org-babel-widgets--redraw w)
      (org-babel-widgets--schedule (org-babel-widgets-widget-name w))
      t)))

(defun org-babel-widgets-set (name value)
  "Set widget NAME to VALUE, redraw it and re-run dependent blocks.
Sliders snap to their step, toggles treat nil and 0 as off, choices must
be one of their options and buttons ignore VALUE and count a click.
Return the new `org-babel-widgets-value'."
  (org-babel-widgets--set-widget (org-babel-widgets--lookup name) value)
  (org-babel-widgets-value name))

(defun org-babel-widgets--step (w n)
  "Move widget W by N steps: slider by N*step, choice cyclically, toggle flips."
  (pcase (org-babel-widgets-widget-type w)
    ('slider (org-babel-widgets--set-widget w (+ (org-babel-widgets-widget-value w) (* n (org-babel-widgets-widget-step w)))))
    ('toggle (org-babel-widgets--set-widget w (not (org-babel-widgets-widget-value w))))
    ('choice (let* ((opts (org-babel-widgets-widget-options w))
                    (i (cl-position (org-babel-widgets-widget-value w) opts :test #'equal)))
               (org-babel-widgets--set-widget w (nth (mod (+ i (if (> n 0) 1 -1)) (length opts))
                                      opts))))))

(defun org-babel-widgets--activate (w)
  "Primary action for widget W: click, flip, or prompt for a value."
  (pcase (org-babel-widgets-widget-type w)
    ('button (org-babel-widgets--set-widget w nil))
    ('toggle (org-babel-widgets--set-widget w (not (org-babel-widgets-widget-value w))))
    ('choice (org-babel-widgets--set-widget w (completing-read (format "%s: " (org-babel-widgets-widget-label w))
                                                (org-babel-widgets-widget-options w) nil t
                                                nil nil (org-babel-widgets-widget-value w))))
    ('slider (org-babel-widgets--set-widget w (read-number (format "%s: " (org-babel-widgets-widget-label w))
                                            (org-babel-widgets-widget-value w))))))

;;;; Display

(defun org-babel-widgets--value-text (w)
  "Return the text shown right of widget W's canvas."
  (pcase (org-babel-widgets-widget-type w)
    ('toggle (if (org-babel-widgets-widget-value w) "on" "off"))
    (_ (let ((v (org-babel-widgets-widget-value w)))
         (if (and (org-babel-widgets-widget-continuous w) (floatp v))
             (format "%.4g" v)
           (format "%s" v))))))

(defun org-babel-widgets--string (w)
  "Return the `before-string' displaying widget W."
  (concat (propertize (concat (org-babel-widgets-widget-label w) " ") 'face 'default)
          (propertize " " 'display (org-babel-widgets-widget-canvas w)
                      'keymap (org-babel-widgets--make-keymap w) 'pointer 'hand)
          (propertize (concat " " (org-babel-widgets--value-text w) "\n") 'face 'default)))

(defun org-babel-widgets--draw (w)
  "Repaint the pixel buffer of widget W from its current state."
  (let* ((canvas (org-babel-widgets-widget-canvas w))
         (vec (plist-get (cdr canvas) :data))
         (width (plist-get (cdr canvas) :data-width))
         (height (plist-get (cdr canvas) :data-height))
         (pressed (org-babel-widgets-widget-pressed w))
         (value (org-babel-widgets-widget-value w)))
    (pcase (org-babel-widgets-widget-type w)
      ('slider (org-babel-widgets--draw-slider vec width height
                                (/ (float (- value (org-babel-widgets-widget-min w)))
                                   (- (org-babel-widgets-widget-max w) (org-babel-widgets-widget-min w)))
                                pressed))
      ('button (org-babel-widgets--draw-button vec width height pressed))
      ('toggle (org-babel-widgets--draw-toggle vec width height value))
      ('choice (org-babel-widgets--draw-choice vec width height pressed)))))

(defun org-babel-widgets--redraw (w)
  "Repaint widget W, refresh its canvas and update its overlay text."
  (org-babel-widgets--draw w)
  (when (display-graphic-p)
    (canvas-refresh (org-babel-widgets-widget-canvas w) t))
  (when-let* ((ov (org-babel-widgets-widget-overlay w))
              ((overlay-buffer ov)))
    (overlay-put ov 'before-string (org-babel-widgets--string w))))

(defun org-babel-widgets--error-overlay (beg end msg)
  "Show error MSG above the line BEG..END."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'cw t)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'before-string (propertize (format "%s\n" msg) 'face 'error))))

(defun org-babel-widgets--install (w beg end)
  "Create the overlay for widget W on the line BEG..END and draw it."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'cw t)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'face 'shadow)
    (overlay-put ov 'keymap (org-babel-widgets--make-line-keymap w))
    (setf (org-babel-widgets-widget-overlay w) ov)
    (org-babel-widgets--redraw w)))

(defun org-babel-widgets--carry-over (new old)
  "Copy OLD's runtime value into NEW when both are the same kind of widget."
  (when (eq (org-babel-widgets-widget-type new) (org-babel-widgets-widget-type old))
    (pcase (org-babel-widgets-widget-type new)
      ('slider (setf (org-babel-widgets-widget-value new) (org-babel-widgets--snap new (org-babel-widgets-widget-value old))))
      ('choice (when (member (org-babel-widgets-widget-value old) (org-babel-widgets-widget-options new))
                 (setf (org-babel-widgets-widget-value new) (org-babel-widgets-widget-value old))))
      (_ (setf (org-babel-widgets-widget-value new) (org-babel-widgets-widget-value old))))))

(defun org-babel-widgets--scan-lines ()
  "Return widget declarations in the buffer as (NAME TYPE REST SPEC BEG END)."
  (let (out (case-fold-search t))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (re-search-forward org-babel-widgets--line-re nil t)
          (push (list (match-string-no-properties 1) (match-string-no-properties 2)
                      (match-string-no-properties 3) (match-string-no-properties 0)
                      (match-beginning 0) (match-end 0))
                out))))
    (nreverse out)))

(defun org-babel-widgets--rescan ()
  "Synchronize widgets and overlays with the #+WIDGET lines in the buffer."
  (let* ((table (org-babel-widgets--table))
         (lines (org-babel-widgets--scan-lines))
         (seen (make-hash-table :test #'equal))
         (kept nil)
         (fresh nil))
    ;; Classify each line: keep an unchanged widget, build a new one, or flag an error.
    (dolist (line lines)
      (pcase-let ((`(,name ,type ,rest ,spec ,beg ,end) line))
        (cond
         ((gethash name seen)
          (push (list :error beg end (format "Widget error: duplicate widget %s" name)) fresh))
         (t
          (puthash name t seen)
          (let ((old (gethash name table)))
            (if (and old (equal spec (org-babel-widgets-widget-spec old))
                     (org-babel-widgets-widget-overlay old)
                     (eql (overlay-start (org-babel-widgets-widget-overlay old)) beg))
                (push old kept)
              (condition-case err
                  (let ((w (org-babel-widgets--parse-line name type rest)))
                    (setf (org-babel-widgets-widget-spec w) spec)
                    (when old (org-babel-widgets--carry-over w old))
                    (push (list :widget beg end w) fresh))
                (user-error
                 (push (list :error beg end (error-message-string err)) fresh)
                 (remhash name table)))))))))
    ;; Drop every overlay that is not owned by a kept widget.
    (let ((keep-ovs (mapcar #'org-babel-widgets-widget-overlay kept)))
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (and (overlay-get ov 'cw) (not (memq ov keep-ovs)))
          (delete-overlay ov))))
    (dolist (item (nreverse fresh))
      (pcase item
        (`(:error ,beg ,end ,msg) (org-babel-widgets--error-overlay beg end msg))
        (`(:widget ,beg ,end ,w)
         (puthash (org-babel-widgets-widget-name w) w table)
         (org-babel-widgets--install w beg end))))
    (maphash (lambda (name _w) (unless (gethash name seen) (remhash name table)))
             table)))

(defun org-babel-widgets--rescan-in (buffer)
  "Run `org-babel-widgets--rescan' in BUFFER if the mode is on there.
BUFFER must also be live."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq org-babel-widgets--rescan-timer nil)
      (when org-babel-widgets-mode (org-babel-widgets--rescan)))))

(defun org-babel-widgets--after-change (&rest _)
  "Schedule a rescan of widget declarations after buffer edits."
  (when (timerp org-babel-widgets--rescan-timer) (cancel-timer org-babel-widgets--rescan-timer))
  (setq org-babel-widgets--rescan-timer
        (run-with-idle-timer 0.3 nil #'org-babel-widgets--rescan-in (current-buffer))))

(defun org-babel-widgets--redraw-all (&rest _)
  "Repaint every widget in every buffer using `org-babel-widgets-mode'."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and org-babel-widgets-mode org-babel-widgets--widgets)
        (maphash (lambda (_ w) (org-babel-widgets--redraw w)) org-babel-widgets--widgets)))))

;;;###autoload
(define-minor-mode org-babel-widgets-mode
  "Display `#+WIDGET:' declarations as interactive canvas widgets."
  :lighter " CW"
  (if org-babel-widgets-mode
      (progn
        (unless (display-graphic-p)
          (setq org-babel-widgets-mode nil)
          (user-error "Org-babel-widgets requires a graphical Emacs"))
        (org-babel-widgets--table)
        (org-babel-widgets--rescan)
        (add-hook 'after-change-functions #'org-babel-widgets--after-change nil t)
        (add-hook 'enable-theme-functions #'org-babel-widgets--redraw-all))
    (remove-hook 'after-change-functions #'org-babel-widgets--after-change t)
    (dolist (timer (list org-babel-widgets--timer org-babel-widgets--rescan-timer))
      (when (timerp timer) (cancel-timer timer)))
    (setq org-babel-widgets--timer nil org-babel-widgets--rescan-timer nil org-babel-widgets--pending nil)
    (save-restriction
      (widen)
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (overlay-get ov 'cw) (delete-overlay ov))))
    (when org-babel-widgets--widgets (clrhash org-babel-widgets--widgets))))

;;;; Interaction

(defun org-babel-widgets--pointer-set (w x)
  "Set slider W from pixel X relative to the left edge of its canvas."
  (org-babel-widgets--set-widget w (org-babel-widgets--x->value w x)))

(defun org-babel-widgets--over-canvas-p (w posn left top win)
  "Non-nil if POSN is inside W's canvas, whose origin in WIN is (LEFT, TOP)."
  (and (eq (posn-window posn) win)
       (let ((xy (posn-x-y posn)))
         (and (<= left (car xy)) (< (car xy) (+ left (org-babel-widgets--canvas-width w)))
              (<= top (cdr xy)) (< (cdr xy) (+ top org-babel-widgets-height))))))

(defun org-babel-widgets--mouse (w event)
  "Handle a mouse press EVENT on widget W's canvas, tracking until release."
  (let* ((start (event-start event))
         (win (posn-window start))
         (obj-xy (posn-object-x-y start))
         (left (- (car (posn-x-y start)) (or (car obj-xy) 0)))
         (top (- (cdr (posn-x-y start)) (or (cdr obj-xy) 0)))
         (slider (eq (org-babel-widgets-widget-type w) 'slider))
         (ev nil)
         (activate nil))
    (setf (org-babel-widgets-widget-pressed w) t)
    (unwind-protect
        (progn
          (if slider
              (org-babel-widgets--pointer-set w (or (car obj-xy) 0))
            (org-babel-widgets--redraw w))
          (track-mouse
            (while (progn (setq ev (read-event)) (mouse-movement-p ev))
              (when (and slider (eq (posn-window (event-end ev)) win))
                (org-babel-widgets--pointer-set w (- (car (posn-x-y (event-end ev))) left)))))
          (when (consp ev)
            (let ((end (event-end ev)))
              (if slider
                  (when (eq (posn-window end) win)
                    (org-babel-widgets--pointer-set w (- (car (posn-x-y end)) left)))
                (setq activate (org-babel-widgets--over-canvas-p w end left top win))))))
      (setf (org-babel-widgets-widget-pressed w) nil)
      (org-babel-widgets--redraw w))
    (when activate (org-babel-widgets--activate w))))

(defun org-babel-widgets--make-keymap (w)
  "Return the mouse keymap attached to the canvas text of widget W."
  (define-keymap
    "<down-mouse-1>" (lambda (event)
                       (interactive "e")
                       (org-babel-widgets--mouse w event))))

(defun org-babel-widgets--make-line-keymap (w)
  "Return the keyboard keymap active on the declaration line of widget W."
  (define-keymap
    "C-<left>" (lambda () (interactive) (org-babel-widgets--step w -1))
    "C-<right>" (lambda () (interactive) (org-babel-widgets--step w 1))
    "C-S-<left>" (lambda () (interactive) (org-babel-widgets--step w (if (eq (org-babel-widgets-widget-type w) 'slider) -10 -1)))
    "C-S-<right>" (lambda () (interactive) (org-babel-widgets--step w (if (eq (org-babel-widgets-widget-type w) 'slider) 10 1)))
    "C-c C-c" (lambda () (interactive) (org-babel-widgets--activate w))))

;;;; Babel bridge

(defun org-babel-widgets--dependent-blocks (names)
  "Return markers for source blocks whose header cites any of NAMES.
Blocks cite a widget with (org-babel-widgets-value \"NAME\") on their
#+begin_src line.
Markers are in buffer order and must be released by the caller."
  (when names
    (let ((re (concat "^[ \t]*#\\+begin_src[ \t].*(org-babel-widgets-value[ \t]+\""
                      (regexp-opt names) "\""))
          (case-fold-search t)
          out)
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (while (re-search-forward re nil t)
            (push (copy-marker (line-beginning-position)) out)
            (forward-line 1))))
      (nreverse out))))

(defun org-babel-widgets--arm ()
  "(Re)start the debounce timer for `org-babel-widgets--flush'."
  (when (timerp org-babel-widgets--timer) (cancel-timer org-babel-widgets--timer))
  (setq org-babel-widgets--timer (run-with-timer org-babel-widgets-debounce nil #'org-babel-widgets--flush (current-buffer))))

(defun org-babel-widgets--schedule (name)
  "Record that widget NAME changed and debounce the block re-execution."
  (cl-pushnew name org-babel-widgets--pending :test #'equal)
  (org-babel-widgets--arm))

(defun org-babel-widgets--refresh-result-preview ()
  "Refresh inline images in the results of the source block at point."
  (when (display-graphic-p)
    (when-let* ((beg (org-babel-where-is-src-block-result)))
      (save-excursion
        (goto-char beg)
        (forward-line 1)
        (org-link-preview-region nil t beg (org-babel-result-end))))))

(defun org-babel-widgets--flush (buffer)
  "Re-execute blocks depending on changed widgets in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp org-babel-widgets--timer) (cancel-timer org-babel-widgets--timer))
      (setq org-babel-widgets--timer nil)
      (if org-babel-widgets--running
          (org-babel-widgets--arm)
        (let* ((names org-babel-widgets--pending)
               (markers (progn (setq org-babel-widgets--pending nil)
                               (org-babel-widgets--dependent-blocks names))))
          (setq org-babel-widgets--running t)
          (unwind-protect
              (dolist (m markers)
                (condition-case err
                    (save-excursion
                      (goto-char m)
                      (org-babel-execute-src-block)
                      (org-babel-widgets--refresh-result-preview))
                  (error
                   (message "Widget error: block at line %d failed: %s"
                            (line-number-at-pos m t) (error-message-string err)))))
            (setq org-babel-widgets--running nil)
            (dolist (m markers) (set-marker m nil)))
          (when org-babel-widgets--pending (org-babel-widgets--arm)))))))

(provide 'org-babel-widgets)

;;; org-babel-widgets.el ends here

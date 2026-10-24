;;; canvas-widgets.el --- Interactive canvas widgets driving Org Babel blocks  -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "32.0"))

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
;;   #+begin_src python :var amp=(cw-value "NAME")
;;
;; Whenever the widget changes, every block whose #+begin_src line
;; references it is re-executed (debounced) and its image results are
;; refreshed, similar to `ipywidgets.interact'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'ob-core)

(defgroup canvas-widgets nil
  "Interactive canvas widgets for Org Babel."
  :group 'org-babel
  :prefix "cw-")

(defcustom cw-height 20
  "Height in pixels of every widget canvas."
  :type 'natnum)

(defcustom cw-slider-width 200
  "Width in pixels of slider canvases."
  :type 'natnum)

(defcustom cw-debounce 0.12
  "Seconds to wait after the last widget change before re-running blocks."
  :type 'number)

(defface cw-track
  '((((background dark)) :background "#555a66")
    (t :background "#c4c8d0"))
  "Background color of unfilled widget parts."
  :group 'canvas-widgets)

(defface cw-accent
  '((((background dark)) :background "#6ea8fe")
    (t :background "#2f6fe0"))
  "Background color of active widget parts."
  :group 'canvas-widgets)

(defface cw-knob
  '((((background dark)) :background "#f0f2f5")
    (t :background "#ffffff"))
  "Background color of knobs and glyphs."
  :group 'canvas-widgets)

;;;; Rasterizer

(defun cw--parse-color (str)
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

(defun cw--color (face attr)
  "Return ATTR of FACE as opaque ARGB32 integer.
Falls back to the `default' face when FACE does not set ATTR."
  (pcase-let* ((`(,r ,g ,b)
                (or (cw--parse-color (face-attribute face attr nil 'default))
                    (cw--parse-color (face-attribute 'default attr))
                    (if (eq attr :foreground) '(255 255 255) '(0 0 0)))))
    (logior #xFF000000 (ash r 16) (ash g 8) b)))

(defun cw--blend (dst src alpha)
  "Blend ARGB32 SRC over DST with coverage ALPHA (0.0-1.0); result is opaque."
  (let ((out 0))
    (dolist (sh '(16 8 0))
      (let ((d (logand (ash dst (- sh)) 255))
            (s (logand (ash src (- sh)) 255)))
        (setq out (logior out (ash (round (+ (* d (- 1.0 alpha)) (* s alpha)))
                                   sh)))))
    (logior #xFF000000 out)))

(defun cw--plot (vec w x y color coverage)
  "Blend COLOR with COVERAGE into pixel (X, Y) of VEC (row width W)."
  (when (> coverage 0.0)
    (let ((i (+ (* y w) x)))
      (aset vec i (if (>= coverage 0.999)
                      color
                    (cw--blend (aref vec i) color coverage))))))

(defun cw--fill-circle (vec w cx cy r color)
  "Draw an antialiased filled circle centered (CX, CY), radius R, in VEC."
  (let ((h (/ (length vec) w)))
    (cl-loop for y from (max 0 (floor (- cy r 1))) to (min (1- h) (ceiling (+ cy r 1)))
             do (cl-loop for x from (max 0 (floor (- cx r 1))) to (min (1- w) (ceiling (+ cx r 1)))
                         do (let* ((dx (- (+ x 0.5) cx))
                                   (dy (- (+ y 0.5) cy))
                                   (d (- (sqrt (+ (* dx dx) (* dy dy))) r)))
                              (cw--plot vec w x y color (min 1.0 (- 0.5 d))))))))

(defun cw--fill-rrect (vec w x y width height r color)
  "Draw an antialiased filled rounded rectangle in VEC.
Top-left corner (X, Y), size WIDTH x HEIGHT, corner radius R."
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
                              (cw--plot vec w px py color (min 1.0 (- 0.5 d))))))))

(defun cw--draw-slider (vec w h frac pressed)
  "Redraw slider into VEC (W x H) with fill fraction FRAC (0.0-1.0)."
  (let* ((pad (/ h 2))
         (len (- w (* 2 pad)))
         (cx (+ pad (* frac len)))
         (cy (/ h 2.0))
         (ty (/ (- h 4) 2.0))
         (track (cw--color 'cw-track :background))
         (accent (cw--color 'cw-accent :background))
         (knob (cw--color 'cw-knob :background)))
    (fillarray vec (cw--color 'default :background))
    (cw--fill-rrect vec w pad ty len 4 2 track)
    (when (>= (- cx pad) 1)
      (cw--fill-rrect vec w pad ty (- cx pad) 4 2 accent))
    (cw--fill-circle vec w cx cy (- cy 2) accent)
    (cw--fill-circle vec w cx cy (- cy 4) (if pressed accent knob))))

(defun cw--draw-button (vec w h pressed)
  "Redraw button into VEC (W x H)."
  (fillarray vec (cw--color 'default :background))
  (cw--fill-rrect vec w 1 1 (- w 2) (- h 2) 4
                  (cw--color (if pressed 'cw-accent 'cw-track) :background))
  (cw--fill-circle vec w (/ w 2.0) (/ h 2.0) (- (/ h 2.0) 6)
                   (cw--color 'cw-knob :background)))

(defun cw--draw-toggle (vec w h on)
  "Redraw toggle into VEC (W x H); ON non-nil draws the active state."
  (fillarray vec (cw--color 'default :background))
  (cw--fill-rrect vec w 2 2 (- w 4) (- h 4) (- (/ h 2.0) 2)
                  (cw--color (if on 'cw-accent 'cw-track) :background))
  (cw--fill-circle vec w (if on (- w (/ h 2.0)) (/ h 2.0)) (/ h 2.0)
                   (- (/ h 2.0) 5) (cw--color 'cw-knob :background)))

(defun cw--draw-choice (vec w h pressed)
  "Redraw choice button into VEC (W x H)."
  (let ((cx (/ w 2.0))
        (cy (/ h 2.0))
        (knob (cw--color 'cw-knob :background)))
    (fillarray vec (cw--color 'default :background))
    (cw--fill-rrect vec w 1 1 (- w 2) (- h 2) 4
                    (cw--color (if pressed 'cw-accent 'cw-track) :background))
    (cw--fill-circle vec w (- cx 3) (- cy 1) 1.2 knob)
    (cw--fill-circle vec w cx (+ cy 2) 1.2 knob)
    (cw--fill-circle vec w (+ cx 3) (- cy 1) 1.2 knob)))

;;;; Model

(cl-defstruct cw-widget
  name type value min max step options label canvas overlay spec pressed continuous)

(defvar-local cw--widgets nil
  "Hash table mapping widget names to `cw-widget' structs in this buffer.")

(defvar-local cw--pending nil
  "Names of widgets changed since the last block re-execution.")

(defvar-local cw--timer nil
  "Pending debounce timer for `cw--flush'.")

(defvar-local cw--running nil
  "Non-nil while `cw--flush' is executing blocks.")

(defvar-local cw--rescan-timer nil
  "Idle timer scheduled by `cw--after-change'.")

(defvar canvas-widgets-mode)

(defconst cw--types '(slider button toggle choice))

(defconst cw--line-re
  (rx bol "#+WIDGET:" (* (any " \t"))
      (group (* (not (any " \t\n")))) (* (any " \t"))
      (group (* (not (any " \t\n")))) (* (any " \t"))
      (group (* nonl)) eol)
  "Match a widget declaration: groups are NAME, TYPE and the option text.")

(defun cw--table ()
  "Return this buffer's widget table, creating it if needed."
  (or cw--widgets (setq cw--widgets (make-hash-table :test #'equal))))

(defun cw--clean (w v)
  "Remove float noise from V according to the number format of slider W."
  (if (and (integerp (cw-widget-min w)) (integerp (cw-widget-step w))
           (not (cw-widget-continuous w)))
      (round v)
    (string-to-number (format "%.10g" v))))

(defun cw--snap (w raw)
  "Clamp RAW to slider W's range; snap to its step unless W is continuous."
  (let* ((mn (cw-widget-min w))
         (mx (cw-widget-max w))
         (clamped (max mn (min mx raw))))
    (if (cw-widget-continuous w)
        (cw--clean w clamped)
      (let* ((n (round (/ (- clamped mn) (float (cw-widget-step w)))))
             (v (+ mn (* (cw-widget-step w) n))))
        (cw--clean w (max mn (min mx v)))))))

(defun cw--canvas-width (w)
  "Return the pixel width of widget W's canvas."
  (plist-get (cdr (cw-widget-canvas w)) :data-width))

(defun cw--x->value (w x)
  "Return slider W's value for pixel X relative to the left of its canvas."
  (let* ((width (cw--canvas-width w))
         (pad (/ cw-height 2))
         (frac (max 0.0 (min 1.0 (/ (- x pad) (float (- width (* 2 pad))))))))
    (cw--snap w (+ (cw-widget-min w)
                   (* frac (- (cw-widget-max w) (cw-widget-min w)))))))

(defun cw--new-canvas (type)
  "Return a fresh canvas image spec sized for widget TYPE."
  (let ((width (pcase type
                 ('slider cw-slider-width)
                 ('button 32)
                 ('toggle 36)
                 ('choice 24))))
    (create-image (make-vector (* width cw-height) 0) 'canvas t
                  :data-width width :data-height cw-height)))

(defun cw--parse-line (name type rest)
  "Return a `cw-widget' for NAME, TYPE and the option text REST.
Signal `user-error' with a \"cw: \" message on invalid input."
  (when (string-empty-p name) (user-error "cw: missing widget name"))
  (let ((sym (and (not (string-empty-p type)) (intern type)))
        plist)
    (unless (memq sym cw--types)
      (user-error "cw: unknown widget type %S (want slider, button, toggle or choice)" type))
    (setq plist
          (condition-case err
              (car (read-from-string (concat "(" rest ")")))
            (error (user-error "cw: cannot read options %S: %s" rest
                               (error-message-string err)))))
    (unless (and (proper-list-p plist) (cl-evenp (length plist)))
      (user-error "cw: options must be :key value pairs"))
    (cl-loop for (k _v) on plist by #'cddr
             unless (memq k '(:min :max :step :value :label :options :continuous))
             do (user-error "cw: unknown option %S" k))
    (let* ((w (make-cw-widget :name name :type sym :spec nil
                              :label (or (plist-get plist :label) name)
                              :canvas (cw--new-canvas sym)))
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
             (user-error "cw: :min, :max and :step must be numbers"))
           (unless (< mn mx) (user-error "cw: :min must be less than :max"))
           (unless (> st 0) (user-error "cw: :step must be positive"))
           (unless (or (null value) (numberp value))
             (user-error "cw: :value must be a number"))
           (setf (cw-widget-min w) mn (cw-widget-max w) mx (cw-widget-step w) st
                 (cw-widget-continuous w) (and (plist-get plist :continuous) t))
           (setf (cw-widget-value w) (cw--snap w (or value mn)))))
        ('toggle (setf (cw-widget-value w) (and value t)))
        ('button (setf (cw-widget-value w) 0))
        ('choice
         (let ((opts (plist-get plist :options)))
           (unless (and (consp opts) (proper-list-p opts) (cl-every #'stringp opts))
             (user-error "cw: choice needs :options as a list of strings"))
           (when (and value (not (member value opts)))
             (user-error "cw: :value %S is not in :options" value))
           (setf (cw-widget-options w) opts
                 (cw-widget-value w) (or value (car opts))))))
      w)))

(defun cw--lookup (name)
  "Return the widget called NAME in the current buffer or signal an error."
  (or (gethash name (cw--table))
      (error "cw: no widget named %S in this buffer" name)))

(defun cw-value (name)
  "Return the current value of widget NAME in the current buffer.
Sliders give a number, toggles 1 or 0, buttons their click count and
choices the selected string."
  (let ((w (cw--lookup name)))
    (pcase (cw-widget-type w)
      ('toggle (if (cw-widget-value w) 1 0))
      (_ (cw-widget-value w)))))

(defun cw--set-widget (w value)
  "Set widget W to VALUE and return non-nil if its value changed.
A change redraws W and schedules dependent blocks."
  (let* ((old (cw-widget-value w))
         (new (pcase (cw-widget-type w)
                ('slider (cw--snap w value))
                ('toggle (and value (not (eql value 0)) t))
                ('button (1+ old))
                ('choice (if (member value (cw-widget-options w))
                             value
                           (user-error "cw: %S is not one of %S" value
                                       (cw-widget-options w)))))))
    (unless (equal old new)
      (setf (cw-widget-value w) new)
      (cw--redraw w)
      (cw--schedule (cw-widget-name w))
      t)))

(defun cw-set (name value)
  "Set widget NAME to VALUE, redraw it and re-run dependent blocks.
Sliders snap to their step, toggles treat nil and 0 as off, choices must
be one of their options and buttons ignore VALUE and count a click.
Return the new `cw-value'."
  (cw--set-widget (cw--lookup name) value)
  (cw-value name))

(defun cw--step (w n)
  "Move widget W by N steps: slider by N*step, choice cyclically, toggle flips."
  (pcase (cw-widget-type w)
    ('slider (cw--set-widget w (+ (cw-widget-value w) (* n (cw-widget-step w)))))
    ('toggle (cw--set-widget w (not (cw-widget-value w))))
    ('choice (let* ((opts (cw-widget-options w))
                    (i (cl-position (cw-widget-value w) opts :test #'equal)))
               (cw--set-widget w (nth (mod (+ i (if (> n 0) 1 -1)) (length opts))
                                      opts))))))

(defun cw--activate (w)
  "Primary action for widget W: click, flip, or prompt for a value."
  (pcase (cw-widget-type w)
    ('button (cw--set-widget w nil))
    ('toggle (cw--set-widget w (not (cw-widget-value w))))
    ('choice (cw--set-widget w (completing-read (format "%s: " (cw-widget-label w))
                                                (cw-widget-options w) nil t
                                                nil nil (cw-widget-value w))))
    ('slider (cw--set-widget w (read-number (format "%s: " (cw-widget-label w))
                                            (cw-widget-value w))))))

;;;; Display

(defun cw--value-text (w)
  "Return the text shown right of widget W's canvas."
  (pcase (cw-widget-type w)
    ('toggle (if (cw-widget-value w) "on" "off"))
    (_ (let ((v (cw-widget-value w)))
         (if (and (cw-widget-continuous w) (floatp v))
             (format "%.4g" v)
           (format "%s" v))))))

(defun cw--string (w)
  "Return the `before-string' displaying widget W."
  (concat (propertize (concat (cw-widget-label w) " ") 'face 'default)
          (propertize " " 'display (cw-widget-canvas w)
                      'keymap (cw--make-keymap w) 'pointer 'hand)
          (propertize (concat " " (cw--value-text w) "\n") 'face 'default)))

(defun cw--draw (w)
  "Repaint the pixel buffer of widget W from its current state."
  (let* ((canvas (cw-widget-canvas w))
         (vec (plist-get (cdr canvas) :data))
         (width (plist-get (cdr canvas) :data-width))
         (height (plist-get (cdr canvas) :data-height))
         (pressed (cw-widget-pressed w))
         (value (cw-widget-value w)))
    (pcase (cw-widget-type w)
      ('slider (cw--draw-slider vec width height
                                (/ (float (- value (cw-widget-min w)))
                                   (- (cw-widget-max w) (cw-widget-min w)))
                                pressed))
      ('button (cw--draw-button vec width height pressed))
      ('toggle (cw--draw-toggle vec width height value))
      ('choice (cw--draw-choice vec width height pressed)))))

(defun cw--redraw (w)
  "Repaint widget W, refresh its canvas and update its overlay text."
  (cw--draw w)
  (when (display-graphic-p)
    (canvas-refresh (cw-widget-canvas w) t))
  (when-let* ((ov (cw-widget-overlay w))
              ((overlay-buffer ov)))
    (overlay-put ov 'before-string (cw--string w))))

(defun cw--error-overlay (beg end msg)
  "Show error MSG above the line BEG..END."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'cw t)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'before-string (propertize (format "%s\n" msg) 'face 'error))))

(defun cw--install (w beg end)
  "Create the overlay for widget W on the line BEG..END and draw it."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'cw t)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'face 'shadow)
    (overlay-put ov 'keymap (cw--make-line-keymap w))
    (setf (cw-widget-overlay w) ov)
    (cw--redraw w)))

(defun cw--carry-over (new old)
  "Copy OLD's runtime value into NEW when both are the same kind of widget."
  (when (eq (cw-widget-type new) (cw-widget-type old))
    (pcase (cw-widget-type new)
      ('slider (setf (cw-widget-value new) (cw--snap new (cw-widget-value old))))
      ('choice (when (member (cw-widget-value old) (cw-widget-options new))
                 (setf (cw-widget-value new) (cw-widget-value old))))
      (_ (setf (cw-widget-value new) (cw-widget-value old))))))

(defun cw--scan-lines ()
  "Return widget declarations in the buffer as (NAME TYPE REST SPEC BEG END)."
  (let (out (case-fold-search t))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (re-search-forward cw--line-re nil t)
          (push (list (match-string-no-properties 1) (match-string-no-properties 2)
                      (match-string-no-properties 3) (match-string-no-properties 0)
                      (match-beginning 0) (match-end 0))
                out))))
    (nreverse out)))

(defun cw--rescan ()
  "Synchronize widgets and overlays with the #+WIDGET lines in the buffer."
  (let* ((table (cw--table))
         (lines (cw--scan-lines))
         (seen (make-hash-table :test #'equal))
         (kept nil)
         (fresh nil))
    ;; Classify each line: keep an unchanged widget, build a new one, or flag an error.
    (dolist (line lines)
      (pcase-let ((`(,name ,type ,rest ,spec ,beg ,end) line))
        (cond
         ((gethash name seen)
          (push (list :error beg end (format "cw: duplicate widget %s" name)) fresh))
         (t
          (puthash name t seen)
          (let ((old (gethash name table)))
            (if (and old (equal spec (cw-widget-spec old))
                     (cw-widget-overlay old)
                     (eql (overlay-start (cw-widget-overlay old)) beg))
                (push old kept)
              (condition-case err
                  (let ((w (cw--parse-line name type rest)))
                    (setf (cw-widget-spec w) spec)
                    (when old (cw--carry-over w old))
                    (push (list :widget beg end w) fresh))
                (user-error
                 (push (list :error beg end (error-message-string err)) fresh)
                 (remhash name table)))))))))
    ;; Drop every overlay that is not owned by a kept widget.
    (let ((keep-ovs (mapcar #'cw-widget-overlay kept)))
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (and (overlay-get ov 'cw) (not (memq ov keep-ovs)))
          (delete-overlay ov))))
    (dolist (item (nreverse fresh))
      (pcase item
        (`(:error ,beg ,end ,msg) (cw--error-overlay beg end msg))
        (`(:widget ,beg ,end ,w)
         (puthash (cw-widget-name w) w table)
         (cw--install w beg end))))
    (maphash (lambda (name _w) (unless (gethash name seen) (remhash name table)))
             table)))

(defun cw--rescan-in (buffer)
  "Run `cw--rescan' in BUFFER if it is live and `canvas-widgets-mode' is on."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq cw--rescan-timer nil)
      (when canvas-widgets-mode (cw--rescan)))))

(defun cw--after-change (&rest _)
  "Schedule a rescan of widget declarations after buffer edits."
  (when (timerp cw--rescan-timer) (cancel-timer cw--rescan-timer))
  (setq cw--rescan-timer
        (run-with-idle-timer 0.3 nil #'cw--rescan-in (current-buffer))))

(defun cw--redraw-all (&rest _)
  "Repaint every widget in every buffer using `canvas-widgets-mode'."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and canvas-widgets-mode cw--widgets)
        (maphash (lambda (_ w) (cw--redraw w)) cw--widgets)))))

;;;###autoload
(define-minor-mode canvas-widgets-mode
  "Display `#+WIDGET:' declarations as interactive canvas widgets."
  :lighter " CW"
  (if canvas-widgets-mode
      (progn
        (unless (display-graphic-p)
          (setq canvas-widgets-mode nil)
          (user-error "canvas-widgets requires a graphical Emacs"))
        (cw--table)
        (cw--rescan)
        (add-hook 'after-change-functions #'cw--after-change nil t)
        (add-hook 'enable-theme-functions #'cw--redraw-all))
    (remove-hook 'after-change-functions #'cw--after-change t)
    (dolist (timer (list cw--timer cw--rescan-timer))
      (when (timerp timer) (cancel-timer timer)))
    (setq cw--timer nil cw--rescan-timer nil cw--pending nil)
    (save-restriction
      (widen)
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (overlay-get ov 'cw) (delete-overlay ov))))
    (when cw--widgets (clrhash cw--widgets))))

;;;; Interaction

(defun cw--pointer-set (w x)
  "Set slider W from pixel X relative to the left edge of its canvas."
  (cw--set-widget w (cw--x->value w x)))

(defun cw--over-canvas-p (w posn left top win)
  "Non-nil if POSN is inside W's canvas, whose origin in WIN is (LEFT, TOP)."
  (and (eq (posn-window posn) win)
       (let ((xy (posn-x-y posn)))
         (and (<= left (car xy)) (< (car xy) (+ left (cw--canvas-width w)))
              (<= top (cdr xy)) (< (cdr xy) (+ top cw-height))))))

(defun cw--mouse (w event)
  "Handle a mouse press EVENT on widget W's canvas, tracking until release."
  (let* ((start (event-start event))
         (win (posn-window start))
         (obj-xy (posn-object-x-y start))
         (left (- (car (posn-x-y start)) (or (car obj-xy) 0)))
         (top (- (cdr (posn-x-y start)) (or (cdr obj-xy) 0)))
         (slider (eq (cw-widget-type w) 'slider))
         (ev nil)
         (activate nil))
    (setf (cw-widget-pressed w) t)
    (unwind-protect
        (progn
          (if slider
              (cw--pointer-set w (or (car obj-xy) 0))
            (cw--redraw w))
          (track-mouse
            (while (progn (setq ev (read-event)) (mouse-movement-p ev))
              (when (and slider (eq (posn-window (event-end ev)) win))
                (cw--pointer-set w (- (car (posn-x-y (event-end ev))) left)))))
          (when (consp ev)
            (let ((end (event-end ev)))
              (if slider
                  (when (eq (posn-window end) win)
                    (cw--pointer-set w (- (car (posn-x-y end)) left)))
                (setq activate (cw--over-canvas-p w end left top win))))))
      (setf (cw-widget-pressed w) nil)
      (cw--redraw w))
    (when activate (cw--activate w))))

(defun cw--make-keymap (w)
  "Return the mouse keymap attached to the canvas text of widget W."
  (define-keymap
    "<down-mouse-1>" (lambda (event)
                       (interactive "e")
                       (cw--mouse w event))))

(defun cw--make-line-keymap (w)
  "Return the keyboard keymap active on the declaration line of widget W."
  (define-keymap
    "C-<left>" (lambda () (interactive) (cw--step w -1))
    "C-<right>" (lambda () (interactive) (cw--step w 1))
    "C-S-<left>" (lambda () (interactive) (cw--step w (if (eq (cw-widget-type w) 'slider) -10 -1)))
    "C-S-<right>" (lambda () (interactive) (cw--step w (if (eq (cw-widget-type w) 'slider) 10 1)))
    "C-c C-c" (lambda () (interactive) (cw--activate w))))

;;;; Babel bridge

(defun cw--dependent-blocks (names)
  "Return markers for source blocks whose header cites any of NAMES.
Blocks cite a widget with (cw-value \"NAME\") on their #+begin_src line.
Markers are in buffer order and must be released by the caller."
  (when names
    (let ((re (concat "^[ \t]*#\\+begin_src[ \t].*(cw-value[ \t]+\""
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

(defun cw--arm ()
  "(Re)start the debounce timer for `cw--flush' in the current buffer."
  (when (timerp cw--timer) (cancel-timer cw--timer))
  (setq cw--timer (run-with-timer cw-debounce nil #'cw--flush (current-buffer))))

(defun cw--schedule (name)
  "Record that widget NAME changed and debounce the block re-execution."
  (cl-pushnew name cw--pending :test #'equal)
  (cw--arm))

(defun cw--refresh-result-preview ()
  "Refresh inline images in the results of the source block at point."
  (when (display-graphic-p)
    (when-let* ((beg (org-babel-where-is-src-block-result)))
      (save-excursion
        (goto-char beg)
        (forward-line 1)
        (org-link-preview-region nil t beg (org-babel-result-end))))))

(defun cw--flush (buffer)
  "Re-execute blocks depending on changed widgets in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp cw--timer) (cancel-timer cw--timer))
      (setq cw--timer nil)
      (if cw--running
          (cw--arm)
        (let* ((names cw--pending)
               (markers (progn (setq cw--pending nil)
                               (cw--dependent-blocks names))))
          (setq cw--running t)
          (unwind-protect
              (dolist (m markers)
                (condition-case err
                    (save-excursion
                      (goto-char m)
                      (org-babel-execute-src-block)
                      (cw--refresh-result-preview))
                  (error
                   (message "cw: block at line %d failed: %s"
                            (line-number-at-pos m t) (error-message-string err)))))
            (setq cw--running nil)
            (dolist (m markers) (set-marker m nil)))
          (when cw--pending (cw--arm)))))))

(provide 'canvas-widgets)

;;; canvas-widgets.el ends here

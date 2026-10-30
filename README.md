# org-babel-widgets

Interactive widgets for Org Babel, drawn on Emacs 32 `canvas` images. Think
`ipywidgets.interact`, but native to Emacs: no Jupyter notebook required.

Declare a widget on a line of your Org buffer:

```org
#+WIDGET: amp slider :min 0 :max 5 :step 0.1 :value 1 :label "amplitude"
```

Read its value from any source block with `:var`:

```org
#+begin_src jupyter-python :var amp=(org-babel-widgets-value "amp")
...
#+end_src
```

Drag the slider (or click a button, flip a toggle, pick a choice) and every
block that references the widget is re-executed. Image results, such as
matplotlib figures, are refreshed inline.

## Features

- Widget types: `slider` (stepped or `:continuous t`), `toggle`, `button`, `choice`.
- Mouse (drag, click) and keyboard control.
- Language-agnostic: the value reaches the block through `:var`, which Org
  evaluates as Emacs Lisp. Tested with `emacs-lisp` and `jupyter-python`.
- Debounced re-execution (only blocks citing the changed widget run, in
  buffer order; an error in one block does not stop the others).
- Pure Emacs Lisp: a small anti-aliased rasterizer over the `canvas` pixel
  buffer. No C module.
- Colors follow the theme through three faces: `org-babel-widgets-track`, `org-babel-widgets-accent`, `org-babel-widgets-knob`.

## Requirements

- Emacs 32 with `canvas` image support, in a graphical frame
  (`(image-type-available-p 'canvas)` must return `t`).
- Org 9.8 or newer (uses `org-link-preview-region` to refresh result images).
- For Jupyter blocks: [emacs-jupyter](https://github.com/emacs-jupyter/jupyter)
  and a kernel (`pip install ipykernel`, then
  `python -m ipykernel install --user --name my-kernel`).

## Installation

Clone the repository and load the library:

```elisp
(use-package org-babel-widgets
  :load-path "~/path/to/org-babel-widgets"
  :hook (org-mode . (lambda ()
                      (when (display-graphic-p)
                        (org-babel-widgets-mode 1)))))
```

Or enable it by hand in an Org buffer with `M-x org-babel-widgets-mode`.

## Usage

### Declaring widgets

```
#+WIDGET: NAME TYPE [:option value ...]
```

| Type     | Options                                                  | `org-babel-widgets-value` returns        |
|----------|----------------------------------------------------------|---------------------------|
| `slider` | `:min` (0) `:max` (1) `:step` (0.01) `:value` `:continuous` | number                  |
| `toggle` | `:value` (nil)                                           | `1` or `0`                |
| `button` | none                                                     | number of clicks          |
| `choice` | `:options ("a" "b" ...)` (required) `:value`             | selected string           |

All types accept `:label "text"`. Options are read as Lisp data, never evaluated.

With `:continuous t` a slider does not snap to a step; its resolution is the
slider width in pixels and the displayed value has 4 significant digits. `:step`
then only sets how far the arrow keys move (default: 1/100 of the range).

Slider `:min`, `:max`, `:step` and `:value` accept arithmetic expressions:

```org
#+WIDGET: theta slider :min 0 :max (* 2 pi) :continuous t :label "theta"
```

They are not passed to `eval`: opening an Org file must never run arbitrary
code. Only numbers, the constants `pi`, `float-pi`, `e` and `float-e`, and these
functions (nested as needed) are allowed: `+ - * / % mod 1+ 1- abs min max expt
sqrt exp log sin cos tan asin acos atan float round floor ceiling truncate`.
Anything else, a division by zero or a non-finite result is reported as a
widget error. Values are computed once, when the line is read.

Invalid declarations show the error in red in place of the widget, for example
`Widget error: :min must be less than :max`. Edited `#+WIDGET:` lines are re-read after
0.3 s of idle time.

### Using values in blocks

```org
#+WIDGET: n slider :min 0 :max 20 :step 1 :value 5 :label "n"

#+begin_src emacs-lisp :var n=(org-babel-widgets-value "n")
(* n n)
#+end_src
```

The reference `(org-babel-widgets-value "name")` must be on the `#+begin_src` line itself
(not on a `#+HEADER:` line) for the block to be re-run when the widget changes.
Do not use `t` as a variable name in Emacs Lisp blocks.

### Controls

| Action                                     | Effect                                                         |
|--------------------------------------------|----------------------------------------------------------------|
| Drag a slider                              | Sets the value live                                            |
| Click a button, toggle or choice           | Counts a click, flips, or prompts for an option                |
| `C-<left>` / `C-<right>` on the widget line | One step down/up (choice: previous/next; toggle: flip)         |
| `C-S-<left>` / `C-S-<right>`               | Ten steps (slider only)                                        |
| `C-c C-c` on the widget line               | Click/flip; prompts for a number (slider) or option (choice)   |

### Widget builder

Two commands write the declarations for you, so you do not have to remember
the syntax:

- `M-x org-babel-widgets-insert-widget`: asks for the type, a name (rejected if
  empty, containing spaces or double quotes, or already declared in the buffer),
  an optional label and the options of that type (slider: minimum, maximum,
  continuous or step, initial value; toggle: initial state; choice:
  comma-separated options and initial one). It inserts the `#+WIDGET:` line on a
  new line below point. Invalid combinations, such as a minimum above the
  maximum, are reported and the options are asked again.
- `M-x org-babel-widgets-insert-var`: with point inside a source block, pick a
  declared widget and a variable name; it appends
  `:var NAME=(org-babel-widgets-value "widget")` to the `#+begin_src` line.

Neither command has a key binding by default. For example:

```elisp
(with-eval-after-load 'org
  (keymap-set org-mode-map "C-c w w" #'org-babel-widgets-insert-widget)
  (keymap-set org-mode-map "C-c w v" #'org-babel-widgets-insert-var))
```

### Lisp API

- `(org-babel-widgets-value NAME)`: current value of widget `NAME` in the current buffer.
- `(org-babel-widgets-set NAME VALUE)`: set a widget programmatically (sliders snap to their
  step, toggles treat `nil` and `0` as off, buttons count a click); redraws and
  schedules dependent blocks.

Customization (group `org-babel-widgets`): `org-babel-widgets-height` (20), `org-babel-widgets-slider-width`
(200), `org-babel-widgets-debounce` (0.12 s between the last change and re-execution).

## Example: live matplotlib plot

```org
#+WIDGET: amp slider :min 0 :max 5 :step 0.1 :value 1 :label "amplitude"
#+WIDGET: freq slider :min 1 :max 10 :step 1 :value 3 :label "frequency"

#+begin_src jupyter-python :session demo :kernel my-kernel :file plot.png :var amp=(org-babel-widgets-value "amp") :var freq=(org-babel-widgets-value "freq")
import matplotlib.pyplot as plt, numpy as np
x = np.linspace(0, 2*np.pi, 400)
fig, ax = plt.subplots(figsize=(6, 3))
ax.plot(x, amp*np.sin(freq*x))
ax.set_ylim(-5.5, 5.5)
plt.close(fig)
fig
#+end_src
```

Run the block once with `C-c C-c`; after that, moving the widgets updates the
image. A `:session` keeps the kernel alive, which keeps dragging smooth.
See `examples/demo.org` (plain `python` session) and `teste.org` (Portuguese
walkthrough with `emacs-lisp` and `jupyter-python` blocks).

## Known issues and limitations

- **emacs-jupyter with Org 9.8**: results other than `:results output`
  fail with `wrong-type-argument wholenump nil`, because the `RESULTS` drawer
  built by emacs-jupyter lacks the `:pre-blank` property that Org 9.8
  requires. Workaround:

  ```elisp
  (with-eval-after-load 'jupyter-org-client
    (advice-add 'jupyter-org-results-drawer :filter-return
                (lambda (drawer)
                  (org-element-put-property drawer :pre-blank 0)
                  drawer)))
  ```

- Widget values live in the session; they are not written to the file
  (`:value` is only the initial value).
- Synchronous blocks block the UI while they run. Use `:session`, a larger
  `org-babel-widgets-debounce`, or cheaper blocks for continuous sliders.
- Widgets contain no text: labels and values are ordinary buffer text next to
  the canvas.
- Asynchronous blocks (`:async yes`) return immediately and are only protected
  by the debounce.

## Tests

```sh
emacs -Q --batch -L . -l test/org-babel-widgets-test.el -f ert-run-tests-batch-and-exit
```

## Files

- `org-babel-widgets.el`: the library (prefix `org-babel-widgets-`).
- `test/org-babel-widgets-test.el`: ERT tests.
- `examples/demo.org`, `teste.org`: example documents.
- `LICENSE`: GNU GPL version 2.

## License

GNU General Public License, version 2 or (at your option) any later version.
See [LICENSE](LICENSE).

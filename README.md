# org-babel-widgets

Interactive widgets for Org Babel, drawn on Emacs 32 `canvas` images. Think
`ipywidgets.interact`, but native to Emacs: no Jupyter notebook required.

Declare a widget on a line of your Org buffer:

```org
#+WIDGET: amp slider :min 0 :max 5 :step 0.1 :value 1 :label "amplitude"
```

Read its value from any source block with `:var`:

```org
#+begin_src jupyter-python :var amp=(cw-value "amp")
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
- Colors follow the theme through three faces: `cw-track`, `cw-accent`, `cw-knob`.

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

| Type     | Options                                                  | `cw-value` returns        |
|----------|----------------------------------------------------------|---------------------------|
| `slider` | `:min` (0) `:max` (1) `:step` (0.01) `:value` `:continuous` | number                  |
| `toggle` | `:value` (nil)                                           | `1` or `0`                |
| `button` | none                                                     | number of clicks          |
| `choice` | `:options ("a" "b" ...)` (required) `:value`             | selected string           |

All types accept `:label "text"`. Options are read as Lisp data, never evaluated.

With `:continuous t` a slider does not snap to a step; its resolution is the
slider width in pixels and the displayed value has 4 significant digits. `:step`
then only sets how far the arrow keys move (default: 1/100 of the range).

Invalid declarations show the error in red in place of the widget, for example
`cw: :min must be less than :max`. Edited `#+WIDGET:` lines are re-read after
0.3 s of idle time.

### Using values in blocks

```org
#+WIDGET: n slider :min 0 :max 20 :step 1 :value 5 :label "n"

#+begin_src emacs-lisp :var n=(cw-value "n")
(* n n)
#+end_src
```

The reference `(cw-value "name")` must be on the `#+begin_src` line itself
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

### Lisp API

- `(cw-value NAME)`: current value of widget `NAME` in the current buffer.
- `(cw-set NAME VALUE)`: set a widget programmatically (sliders snap to their
  step, toggles treat `nil` and `0` as off, buttons count a click); redraws and
  schedules dependent blocks.

Customization (group `org-babel-widgets`): `cw-height` (20), `cw-slider-width`
(200), `cw-debounce` (0.12 s between the last change and re-execution).

## Example: live matplotlib plot

```org
#+WIDGET: amp slider :min 0 :max 5 :step 0.1 :value 1 :label "amplitude"
#+WIDGET: freq slider :min 1 :max 10 :step 1 :value 3 :label "frequency"

#+begin_src jupyter-python :session demo :kernel my-kernel :file plot.png :var amp=(cw-value "amp") :var freq=(cw-value "freq")
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
  `cw-debounce`, or cheaper blocks for continuous sliders.
- Widgets contain no text: labels and values are ordinary buffer text next to
  the canvas.
- Asynchronous blocks (`:async yes`) return immediately and are only protected
  by the debounce.

## Tests

```sh
emacs -Q --batch -L . -l test/org-babel-widgets-test.el -f ert-run-tests-batch-and-exit
```

## Files

- `org-babel-widgets.el`: the library (prefix `cw-`).
- `test/org-babel-widgets-test.el`: ERT tests.
- `examples/demo.org`, `teste.org`: example documents.

;;; meow-tests.el --- Modal adapter tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'combobulate-meow)
(combobulate-meow-setup)

(defmacro meow-structural-test-buffer (text &rest body)
  (declare (indent 1))
  `(save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (let ((transient-mark-mode t))
         (insert ,text)
         (treesit-parser-create 'json)
         (goto-char (point-min))
         (meow-mode 1)
         (unwind-protect (progn ,@body)
           (combobulate-meow-clear)
           (meow-mode -1))))))

(ert-deftest meow-syntax-selects-unequal-ranges ()
  (meow-structural-test-buffer "[\"a\", \"long\", \"third\"]"
    (combobulate-meow-select-class-dwim 'strings t)
    (should (meow-beacon-mode-p))
    (should (= 2 (length meow--beacon-overlays)))
    (should (equal '(select . syntax) (meow--selection-type)))
    (should (equal "\"a\"" (buffer-substring-no-properties (region-beginning) (region-end))))
    (meow--beacon-update-overlays)
    (should (= 2 (length meow--beacon-overlays)))))

(ert-deftest meow-syntax-beacon-replay ()
  (meow-structural-test-buffer "[\"a\", \"long\"]"
    (combobulate-meow-select-class-dwim 'strings t)
    (let ((operation (lambda () (interactive)
                       (delete-region (region-beginning) (region-end))
                       (insert "0"))))
      (funcall operation)
      (meow--beacon-apply-command operation))
    (should (equal "[0, 0]" (buffer-string)))
    (should-not combobulate-meow-beacon-active)
    (should-not meow--beacon-overlays)))

(ert-deftest meow-syntax-grabbed-scope ()
  (meow-structural-test-buffer "[\"a\", \"long\", \"third\"]"
    (goto-char 2) (push-mark 13 t t)
    (meow-grab)
    (combobulate-meow-select-class-dwim 'strings)
    (should (= 2 (length combobulate-extension-targets)))
    (should (= 1 (length meow--beacon-overlays)))))

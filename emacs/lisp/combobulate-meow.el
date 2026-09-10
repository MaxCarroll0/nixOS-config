;;; combobulate-meow.el --- Meow adapter for Combobulate -*- lexical-binding: t; -*-
(require 'combobulate-extension)
(require 'meow)
(require 'meow-beacon)

(defvar-local combobulate-meow-beacon-active nil)

(defun combobulate-meow-selection ()
  "Translate an Emacs region into a Meow selection."
  (when (and (bound-and-true-p meow-mode) (use-region-p))
    (meow--select (meow--make-selection '(select . syntax) (mark) (point)) t)))

(defun combobulate-meow-scope-dwim ()
  "Return the current buffer's grabbed region or ordinary inferred scope."
  (or (and (eq combobulate-extension-target-scope 'dwim)
           (eq (meow--second-sel-buffer) (current-buffer))
           (meow--second-sel-bound))
      (combobulate-extension-scope-dwim)))

(defun combobulate-meow-beacon-overlays (original &rest args)
  "Supply syntax beacon ranges or invoke ORIGINAL with ARGS."
  (if (and combobulate-meow-beacon-active
           (eq (cdr (meow--selection-type)) 'syntax))
      (progn
        (meow--beacon-remove-overlays)
        (dolist (target combobulate-extension-targets)
          (let ((beg (plist-get target :beg)) (end (plist-get target :end)))
            (when (and (marker-buffer beg) (< beg end)
                       (not (and (region-active-p)
                                 (= beg (region-beginning)) (= end (region-end)))))
              (meow--beacon-add-overlay-at-region '(select . syntax) beg end
                                                 (meow--direction-backward-p)))))
        (setq meow--beacon-overlays
              (sort meow--beacon-overlays
                    (lambda (a b) (> (overlay-start a) (overlay-start b))))))
    (apply original args)))

(defun combobulate-meow-start-beacons (scope)
  "Turn frozen targets into Meow beacons bounded by SCOPE."
  (unless combobulate-extension-targets (user-error "No matching syntax targets"))
  (goto-char (car scope))
  (push-mark (cdr scope) t t)
  (secondary-selection-from-region)
  (mapc #'delete-overlay combobulate-extension-overlays)
  (setq combobulate-extension-overlays nil combobulate-meow-beacon-active t)
  (let ((target (car combobulate-extension-targets)))
    (meow--select (meow--make-selection '(select . syntax)
                                        (plist-get target :beg)
                                        (plist-get target :end)) t))
  (meow--switch-state 'beacon)
  (meow--beacon-update-overlays))

(defun combobulate-meow-select-class-dwim (selector &optional whole-buffer innermost)
  "Create beacons for SELECTOR within the grabbed or inferred scope."
  (interactive (list (intern (completing-read "Beacon syntax class: "
                                             (combobulate-extension-selectors) nil t))
                     current-prefix-arg (or combobulate-extension-innermost (equal current-prefix-arg '(16)))))
  (let ((scope (if whole-buffer (cons (point-min) (point-max))
                 (combobulate-meow-scope-dwim))))
    (combobulate-extension-select-class-dwim selector scope innermost)
    (combobulate-meow-start-beacons scope)))

(defun combobulate-meow-select-children ()
  "Create beacons for the direct children of the node at point."
  (interactive)
  (let ((scope (combobulate-extension-bounds (combobulate-extension-node))))
    (combobulate-extension-select-class-dwim 'children scope)
    (combobulate-meow-start-beacons scope)))

(defun combobulate-meow-select-query-dwim (query)
  "Create beacons for QUERY within the grabbed or inferred scope."
  (interactive (list (read-string "Beacon tree-sitter query: ")))
  (let ((scope (combobulate-meow-scope-dwim)))
    (combobulate-extension-select-query-dwim query scope)
    (combobulate-meow-start-beacons scope)))

(defun combobulate-meow-clear ()
  "Clear syntax beacons and return to normal state."
  (interactive)
  (setq combobulate-meow-beacon-active nil)
  (combobulate-extension-clear-targets)
  (meow--beacon-remove-overlays)
  (meow--cancel-second-selection)
  (meow--cancel-selection)
  (meow--switch-state 'normal))

(defun combobulate-meow-replay (original command)
  "Replay COMMAND through ORIGINAL while guarding frozen syntax targets."
  (if (not combobulate-meow-beacon-active) (funcall original command)
    (unwind-protect
        (progn
          (dolist (target combobulate-extension-targets)
            (let ((beg (plist-get target :beg)) (end (plist-get target :end)))
              (when (seq-some (lambda (ov) (and (= beg (overlay-start ov))
                                               (= end (overlay-end ov))))
                             meow--beacon-overlays)
                (unless (combobulate-extension-valid-target-p target)
                  (user-error "Beacon target changed; select targets again")))))
          (funcall original command))
      (combobulate-meow-clear))))

(defun combobulate-meow-bounds ()
  "Return bounds for the syntax thing at point."
  (when-let* ((node (combobulate-extension-node)))
    (combobulate-extension-bounds node)))

(defun combobulate-meow-inner ()
  "Return the span of the syntax thing's named children."
  (when-let* ((node (combobulate-extension-node))
              (children (treesit-node-children node t)))
    (cons (treesit-node-start (car children))
          (treesit-node-end (car (last children))))))

(defvar combobulate-meow-map
  (let ((map (copy-keymap combobulate-extension-map)))
    (define-key map (kbd "a") #'combobulate-meow-select-children)
    (define-key map (kbd "b") #'combobulate-meow-select-class-dwim)
    (define-key map (kbd "/") #'combobulate-meow-select-query-dwim)
    (define-key map (kbd "q") #'combobulate-meow-clear)
    map))

(defun combobulate-meow-direct-edit (original &rest args)
  "Run a native beacon edit through ORIGINAL and clean up syntax targets."
  (if (not combobulate-meow-beacon-active) (apply original args)
    (unwind-protect (apply original args) (combobulate-meow-clear))))

(defun combobulate-meow-setup ()
  "Install the Meow-only selection, key, and beacon adapters."
  (add-hook 'combobulate-extension-selection-hook #'combobulate-meow-selection)
  (advice-add 'meow--beacon-update-overlays :around #'combobulate-meow-beacon-overlays)
  (advice-add 'meow--beacon-apply-command :around #'combobulate-meow-replay)
  (advice-add 'meow-beacon-replace :around #'combobulate-meow-direct-edit)
  (advice-add 'meow-beacon-kill-delete :around #'combobulate-meow-direct-edit)
  (meow-thing-register 'syntax #'combobulate-meow-inner #'combobulate-meow-bounds)
  (setf (alist-get ?T meow-char-thing-table) 'syntax)
  (meow-leader-define-key (cons "o" combobulate-meow-map))
  (define-key meow-beacon-state-keymap (kbd "C-c o") combobulate-meow-map))

(provide 'combobulate-meow)

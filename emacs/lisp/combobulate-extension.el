;;; combobulate-extension.el --- Regions and syntax target sets -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'seq)
(require 'treesit)
(require 'combobulate)

(defvar-local combobulate-extension-history nil)
(defvar-local combobulate-extension-target-scope 'dwim)
(defvar-local combobulate-extension-innermost nil)
(defvar-local combobulate-extension-targets nil)
(defvar-local combobulate-extension-overlays nil)
(defvar combobulate-extension-selection-hook nil)
(defvar combobulate-extension-target-hook nil)
(defvar combobulate-extension-selector-providers nil
  "Functions taking SELECTOR, ROOT and SCOPE and returning target plists.")
(defvar combobulate-extension-classes
  '((strings "string" "string_literal" "interpreted_string_literal" "raw_string_literal")
    (functions "function_definition" "function_declaration" "function_expression" "arrow_function" "fun_expression" "function_expression" "method_definition")
    (calls "call" "call_expression" "application_expression")
    (parameters "parameter" "formal_parameter" "required_parameter" "optional_parameter")
    (patterns "match_pattern" "tuple_pattern" "list_pattern" "record_pattern" "constructor_pattern")
    (types "type_definition" "type_binding" "type_alias_declaration")
    (modules "module_definition" "module_type_definition")))

(defun combobulate-extension-language ()
  "Return the language of the parser at point."
  (or (combobulate-primary-language t)
      (when-let* ((parser (car (treesit-parser-list))))
        (treesit-parser-language parser))))

(defun combobulate-extension-root ()
  "Return the active syntax root."
  (or (when-let* ((language (combobulate-extension-language)))
        (treesit-buffer-root-node language))
      (user-error "No syntax parser in this buffer")))

(defun combobulate-extension-node (&optional position)
  "Return the named node at POSITION."
  (let ((node (treesit-node-at (or position (point))
                              (combobulate-extension-language))))
    (while (and node (not (treesit-node-check node 'named)))
      (setq node (treesit-node-parent node)))
    node))

(defun combobulate-extension-bounds (node)
  "Return NODE's bounds."
  (cons (treesit-node-start node) (treesit-node-end node)))

(defun combobulate-extension-safe-p (node)
  "Return whether NODE has reliable editable bounds."
  (and node (not (treesit-node-check node 'missing))
       (not (treesit-node-check node 'has-error))
       (not (equal (treesit-node-type node) "ERROR"))
       (< (treesit-node-start node) (treesit-node-end node))))

(defun combobulate-extension-select-range (bounds &optional restore)
  "Select BOUNDS using ordinary Emacs point and mark."
  (unless restore
    (push (cons (point-marker) (copy-marker (or (mark t) (point))))
          combobulate-extension-history))
  (goto-char (car bounds))
  (push-mark (cdr bounds) t t)
  (setq deactivate-mark nil)
  (run-hooks 'combobulate-extension-selection-hook))

(defun combobulate-extension-select-node-dwim ()
  "Select the named syntax node at point."
  (interactive)
  (if-let* ((node (combobulate-extension-node)))
      (combobulate-extension-select-range (combobulate-extension-bounds node))
    (user-error "No node at point")))

(defun combobulate-extension-expand-selection ()
  "Select the next enclosing named node."
  (interactive)
  (let* ((beg (if (use-region-p) (region-beginning) (point)))
         (end (if (use-region-p) (region-end) (point)))
         (node (combobulate-extension-node beg)))
    (while (and node (<= (treesit-node-end node) end)
                (>= (treesit-node-start node) beg))
      (setq node (treesit-node-parent node)))
    (unless node (user-error "No larger node"))
    (combobulate-extension-select-range (combobulate-extension-bounds node))))

(defun combobulate-extension-contract-selection ()
  "Restore the previous structural selection."
  (interactive)
  (unless combobulate-extension-history (user-error "No previous selection"))
  (let ((bounds (pop combobulate-extension-history)))
    (combobulate-extension-select-range bounds t)
    (set-marker (car bounds) nil)
    (set-marker (cdr bounds) nil)))

(defun combobulate-extension-scope-dwim (&optional scope)
  "Return explicit SCOPE, the active region, or enclosing definition bounds."
  (or scope
      (and (eq combobulate-extension-target-scope 'buffer) (cons (point-min) (point-max)))
      (and (eq combobulate-extension-target-scope 'container)
           (when-let* ((node (combobulate-extension-node))
                       (parent (treesit-node-parent node)))
             (combobulate-extension-bounds parent)))
      (and (use-region-p) (cons (region-beginning) (region-end)))
      (let ((node (combobulate-extension-node)) found)
        (while (and node (not found))
          (when (string-match-p
                 "\\(?:definition\\|declaration\\|function_item\\)\\'"
                 (treesit-node-type node))
            (setq found (combobulate-extension-bounds node)))
          (setq node (treesit-node-parent node)))
        found)
      (cons (point-min) (point-max))))

(defun combobulate-extension-supported-types (types)
  "Return TYPES accepted by the current grammar."
  (seq-filter
   (lambda (type)
     (condition-case nil
         (progn (treesit-query-compile (combobulate-extension-language)
                                      (format "(%s) @node" type) t) t)
       (treesit-query-error nil))) types))

(defun combobulate-extension-selectors ()
  "Return selectors supported by the active grammar."
  (append '(children siblings same-type)
          (mapcar #'car
                  (seq-filter
                   (lambda (entry)
                     (combobulate-extension-supported-types (cdr entry)))
                   combobulate-extension-classes))))

(defun combobulate-extension-disjoint (targets &optional innermost)
  "Deduplicate TARGETS and retain disjoint outermost or INNERMOST ranges."
  (let* ((ordered (sort (copy-sequence targets)
                        (lambda (a b)
                          (let ((ab (plist-get a :beg)) (bb (plist-get b :beg)))
                            (if (= ab bb) (> (plist-get a :end) (plist-get b :end))
                              (< ab bb))))))
         result)
    (dolist (target ordered)
      (let ((beg (plist-get target :beg)) (end (plist-get target :end)))
        (when (and (< beg end)
                   (not (seq-some (lambda (x)
                                    (and (= beg (plist-get x :beg))
                                         (= end (plist-get x :end)))) result)))
          (if innermost
              (progn
                (setq result (seq-remove
                              (lambda (x) (and (<= (plist-get x :beg) beg)
                                               (>= (plist-get x :end) end))) result))
                (unless (seq-some (lambda (x) (> (plist-get x :end) beg)) result)
                  (push target result)))
            (unless (seq-some (lambda (x) (> (plist-get x :end) beg)) result)
              (push target result))))))
    (nreverse result)))

(defun combobulate-extension-query (selector &optional scope innermost query)
  "Return targets for SELECTOR within SCOPE, optionally using QUERY."
  (let* ((root (combobulate-extension-root))
         (scope (combobulate-extension-scope-dwim scope))
         (node (combobulate-extension-node))
         (types (if (eq selector 'same-type) (list (treesit-node-type node))
                  (combobulate-extension-supported-types
                   (cdr (assq selector combobulate-extension-classes)))))
         (nodes
          (pcase selector
            ('children (when node (treesit-node-children node t)))
            ('siblings (when-let* ((parent (and node (treesit-node-parent node))))
                         (treesit-node-children parent t)))
            (_ (when (or query types)
                 (mapcar #'cdr
                         (treesit-query-capture
                          root (or query (concat "[" (mapconcat
                                                       (lambda (type) (format "(%s)" type))
                                                       types " ") "] @node"))
                          (car scope) (cdr scope)))))))
         targets)
    (dolist (provider combobulate-extension-selector-providers)
      (setq targets (append targets (funcall provider selector root scope))))
    (dolist (candidate nodes)
      (when (and (combobulate-extension-safe-p candidate)
                 (>= (treesit-node-start candidate) (car scope))
                 (<= (treesit-node-end candidate) (cdr scope)))
        (push (list :beg (treesit-node-start candidate)
                    :end (treesit-node-end candidate)
                    :type (treesit-node-type candidate)) targets)))
    (combobulate-extension-disjoint targets innermost)))

(defun combobulate-extension-clear-targets ()
  "Clear structural targets and their preview."
  (interactive)
  (mapc #'delete-overlay combobulate-extension-overlays)
  (dolist (target combobulate-extension-targets)
    (set-marker (plist-get target :beg) nil)
    (set-marker (plist-get target :end) nil))
  (setq combobulate-extension-overlays nil combobulate-extension-targets nil))

(defun combobulate-extension-set-targets (targets)
  "Freeze and preview TARGETS independently of any modal editor."
  (combobulate-extension-clear-targets)
  (dolist (target targets)
    (let* ((beg (plist-get target :beg)) (end (plist-get target :end))
           (ov (make-overlay beg end)))
      (overlay-put ov 'face 'lazy-highlight)
      (push ov combobulate-extension-overlays)
      (push (list :beg (copy-marker beg t) :end (copy-marker end)
                  :type (plist-get target :type)
                  :text (buffer-substring-no-properties beg end))
            combobulate-extension-targets)))
  (setq combobulate-extension-targets (nreverse combobulate-extension-targets))
  (run-hooks 'combobulate-extension-target-hook)
  (message "%d syntax targets" (length targets)))

(defun combobulate-extension-select-class-dwim (selector &optional scope innermost)
  "Preview SELECTOR matches in inferred or explicit SCOPE."
  (interactive
   (list (intern (completing-read "Syntax class: "
                                 (combobulate-extension-selectors) nil t))
         (when current-prefix-arg (cons (point-min) (point-max)))
         (or combobulate-extension-innermost (equal current-prefix-arg '(16)))))
  (combobulate-extension-set-targets
   (combobulate-extension-query selector scope innermost)))

(defun combobulate-extension-select-children ()
  "Preview all direct named children of the node at point."
  (interactive)
  (combobulate-extension-select-class-dwim
   'children (combobulate-extension-bounds (combobulate-extension-node))))

(defun combobulate-extension-select-query-dwim (query &optional scope)
  "Preview QUERY captures within inferred or explicit SCOPE."
  (interactive (list (read-string "Tree-sitter query: ")
                     (when current-prefix-arg (cons (point-min) (point-max)))))
  (combobulate-extension-set-targets
   (combobulate-extension-query 'query scope combobulate-extension-innermost query)))

(defun combobulate-extension-valid-target-p (target)
  "Return whether frozen TARGET still identifies its original text."
  (let ((beg (plist-get target :beg)) (end (plist-get target :end)))
    (and (marker-buffer beg) (eq (marker-buffer beg) (current-buffer))
         (<= (point-min) beg) (< beg end) (<= end (point-max))
         (equal (plist-get target :text)
                (buffer-substring-no-properties beg end)))))

(defun combobulate-extension-apply-targets (function)
  "Apply FUNCTION to each frozen target as one undoable edit."
  (unless combobulate-extension-targets (user-error "No syntax targets"))
  (unless (seq-every-p #'combobulate-extension-valid-target-p combobulate-extension-targets)
    (user-error "Syntax targets changed; select them again"))
  (undo-boundary)
  (atomic-change-group
    (save-mark-and-excursion
      (dolist (target (reverse combobulate-extension-targets))
        (unless (combobulate-extension-valid-target-p target)
          (user-error "A target changed during the batch"))
        (funcall function (plist-get target :beg) (plist-get target :end)))))
  (undo-boundary)
  (combobulate-extension-clear-targets))

(defun combobulate-extension-read-envelope ()
  "Read an envelope supported by this language."
  (let ((envelopes (combobulate-read envelope-list)))
    (unless envelopes (user-error "No envelopes for this language"))
    (let ((name (completing-read "Envelope: "
                                 (mapcar (lambda (e) (plist-get e :name)) envelopes)
                                 nil t)))
      (seq-find (lambda (e) (equal name (plist-get e :name))) envelopes))))

(defun combobulate-extension-wrap-range (beg end envelope)
  "Wrap the region BEG to END in ENVELOPE."
  (goto-char beg)
  (push-mark end t t)
  (let ((transient-mark-mode t))
    (combobulate-envelope-expand-instructions (plist-get envelope :template))))

(defun combobulate-extension-wrap-dwim (envelope)
  "Wrap the active region or inferred node in ENVELOPE."
  (interactive (list (combobulate-extension-read-envelope)))
  (unless (use-region-p) (combobulate-extension-select-node-dwim))
  (let* ((beg (region-beginning)) (end (region-end))
         (node (combobulate-extension-node beg)))
    (while (and node (< (treesit-node-end node) end))
      (setq node (treesit-node-parent node)))
    (unless (and (combobulate-extension-safe-p node)
                 (or (equal (cons beg end) (combobulate-extension-bounds node))
                     (let ((children (treesit-node-children node t)))
                       (and (seq-some (lambda (n) (= beg (treesit-node-start n))) children)
                            (seq-some (lambda (n) (= end (treesit-node-end n))) children)))))
      (user-error "Select a complete node or contiguous siblings"))
    (atomic-change-group (combobulate-extension-wrap-range beg end envelope))))

(defun combobulate-extension-wrap-targets (envelope)
  "Wrap each target using ENVELOPE with shared prompt answers."
  (interactive (list (combobulate-extension-read-envelope)))
  (let ((answers (make-hash-table :test #'equal))
        (prompt (symbol-function 'combobulate-envelope-prompt)))
    (cl-letf (((symbol-function 'combobulate-envelope-prompt)
               (lambda (&rest args)
                 (let ((key (seq-take args 2)))
                   (or (gethash key answers)
                       (puthash key (apply prompt args) answers))))))
      (combobulate-extension-apply-targets
       (lambda (beg end) (combobulate-extension-wrap-range beg end envelope))))))

(defun combobulate-extension-set-scope (scope)
  "Choose the scope used by syntax selectors."
  (interactive (list (intern (completing-read "Selector scope: " '(dwim container buffer) nil t))))
  (setq combobulate-extension-target-scope scope)
  (message "Syntax selector scope: %s" scope))

(defun combobulate-extension-toggle-depth ()
  "Toggle between innermost and outermost disjoint syntax matches."
  (interactive)
  (setq combobulate-extension-innermost (not combobulate-extension-innermost))
  (message "Syntax matches: %s" (if combobulate-extension-innermost "innermost" "outermost")))

(defvar combobulate-extension-map
  (let ((map (make-sparse-keymap)))
    (dolist (entry '(("h" . combobulate-navigate-up) ("l" . combobulate-navigate-down)
                     ("j" . combobulate-navigate-next) ("k" . combobulate-navigate-previous)
                     ("s" . combobulate-extension-select-node-dwim)
                     ("e" . combobulate-extension-expand-selection)
                     ("z" . combobulate-extension-contract-selection)
                     ("w" . combobulate-extension-wrap-dwim)
                     ("r" . combobulate-splice-parent) ("D" . combobulate-splice-self)
                     ("d" . combobulate-kill-node-dwim) ("c" . combobulate-clone-node-dwim)
                     ("J" . combobulate-drag-down) ("K" . combobulate-drag-up)
                     ("a" . combobulate-extension-select-children)
                     ("b" . combobulate-extension-select-class-dwim)
                     ("/" . combobulate-extension-select-query-dwim)
                     ("S" . combobulate-extension-set-scope)
                     ("i" . combobulate-extension-toggle-depth)
                     ("W" . combobulate-extension-wrap-targets)
                     ("q" . combobulate-extension-clear-targets)))
      (define-key map (kbd (car entry)) (cdr entry)))
    (define-key map (kbd "?") (lambda () (interactive) (describe-keymap 'combobulate-extension-map)))
    map))

(define-minor-mode combobulate-extension-mode
  "Expose structural selection and target commands."
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c o") combobulate-extension-map) map))

(defun combobulate-extension-enable ()
  "Enable extensions when Combobulate supports this major mode."
  (when-let* ((entry (combobulate-get-registered-language major-mode))
              ((treesit-language-available-p (car entry))))
    (unless (combobulate-read minor-mode (car entry)) (combobulate-mode 1))
    (combobulate-extension-mode 1)))

(provide 'combobulate-extension)

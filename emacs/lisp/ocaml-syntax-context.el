;;; ocaml-syntax-context.el --- OCaml syntax eligibility -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'seq)
(require 'treesit)
(require 'subr-x)

(defvar my/ocaml-snippet-registry)
(declare-function yas-define-snippets "yasnippet")

(defvar-local ocaml-syntax-context-cache nil)
(defvar ocaml-syntax-context-snippet-roles
  '(("list" expression pattern) ("array" expression pattern) ("unit" expression pattern)
    ("tuple" expression pattern type) ("apply" expression) ("record" expression)
    ("format" expression) ("if" expression) ("match" expression) ("try" expression)
    ("fun" expression) ("function" expression) ("begin" expression) ("seq" expression)
    ("while" expression) ("for" expression) ("fordown" expression)
    ("let" expression structure-item) ("letr" expression structure-item)
    ("type" structure-item signature-item) ("abstract" structure-item signature-item)
    ("val" signature-item) ("exception" structure-item signature-item)
    ("external" structure-item signature-item)
    ("module" structure-item) ("modtype" structure-item signature-item)
    ("functor" structure-item) ("letmod" expression) ("firstmod" expression)
    ("open" structure-item signature-item) ("include" structure-item signature-item)
    ("modsig" signature-item)))

(defun ocaml-syntax-context-language ()
  "Return the OCaml grammar appropriate for this buffer."
  (if (derived-mode-p 'neocaml-interface-mode) 'ocaml-interface 'ocaml))

(defun ocaml-syntax-context--lexical (position)
  "Infer a local insertion role at POSITION from bounded tokens."
  (save-excursion
    (goto-char position)
    (let* ((start (max (point-min) (- position 2000)))
           (text (buffer-substring-no-properties start position)))
      (cond
       ((string-match-p "\\_<module[ \t]+type[ \t]+[A-Z][A-Za-z0-9_']*[ \t]*=[ \t\n]*\\'" text) 'module-type)
       ((string-match-p "\\_<module[ \t]+[A-Z][A-Za-z0-9_']*[ \t]*:[ \t\n]*\\'" text) 'module-type)
       ((string-match-p "\\_<module[ \t]+[A-Z][A-Za-z0-9_']*[ \t]*=[ \t\n]*\\'" text) 'module-expression)
       ((string-match-p "\\_<\\(?:open\\|include\\)[ \t]+[A-Za-z0-9_.]*\\'" text) 'module-expression)
       ((string-match-p "\\(?:[^:]\\|\\`\\):[ \t\n]*\\'" text) 'type)
       ((string-match-p "\\_<type[ \t]+[^=\n]+=[ \t\n]*\\'" text) 'type)
       ((string-match-p "\\_<\\(?:let\\|and\\|fun\\)[ \t]+\\'" text) 'pattern)
       ((string-match-p "\\_<\\(?:module\\|type\\|val\\|external\\)[ \t]+\\'" text) 'name)
       ((string-match-p "\\_<\\(?:with\\|function\\)[ \t\n]*|?[ \t\n]*\\'" text) 'pattern)
       ((string-match-p "\\(?:=\\|->\\|\\_<then\\|\\_<else\\|\\_<in\\)[ \t\n]*\\'" text) 'expression)
       ((string-match-p "\\_<struct[ \t\n]*\\'" text) 'structure-item)
       ((string-match-p "\\_<sig[ \t\n]*\\'" text) 'signature-item)))))

(defun ocaml-syntax-context-at (&optional position)
  "Return syntax role, bounds and recovery confidence at POSITION."
  (let* ((position (or position (point)))
         (language (ocaml-syntax-context-language))
         (key (list position (buffer-chars-modified-tick) language)))
    (if (equal key (car ocaml-syntax-context-cache)) (cdr ocaml-syntax-context-cache)
      (let* ((parser (and (treesit-language-available-p language)
                          (treesit-parser-create language)))
             (node (and parser (treesit-node-at
                                (max (point-min) (1- position)) language)))
             (leaf node) role field recovered)
        (while (and node (not role))
          (let ((type (treesit-node-type node)))
            (setq field (treesit-node-field-name node))
            (cond
             ((member type '("comment" "string" "string_content" "quoted_string"))
              (when (< position (treesit-node-end node))
                (setq role (if (equal type "comment") 'comment 'string))))
             ((equal type "ERROR") (setq recovered t))
             ((and (not recovered) (>= (treesit-node-end node) position)
                   (member type '("module_type_path" "module_type_name" "functor_type")))
              (setq role 'module-type))
             ((and (not recovered) (>= (treesit-node-end node) position)
                   (member type '("module_path" "functor" "module_application")))
              (setq role 'module-expression))
             ((and (not recovered) (>= (treesit-node-end node) position)
                   (string-match-p "\\(?:_type\\|type_constructor_path\\|type_variable\\)\\'" type))
              (setq role 'type))
             ((and (not recovered) (>= (treesit-node-end node) position)
                   (string-suffix-p "_pattern" type)) (setq role 'pattern))
             ((and (not recovered) (>= (treesit-node-end node) position) (equal field "pattern")) (setq role 'pattern))
             ((and (not recovered) (>= (treesit-node-end node) position) (equal field "type")) (setq role 'type))
             ((and (not recovered) (>= (treesit-node-end node) position) (equal field "body")
                   (member (treesit-node-type (treesit-node-parent node))
                           '("let_binding" "fun_expression"))) (setq role 'expression))
             ((member type '("structure" "signature"))
              (setq role (if (equal type "structure") 'structure-item 'signature-item)))))
          (setq node (treesit-node-parent node)))
        (unless (memq role '(comment string))
          (when-let* ((lexical (ocaml-syntax-context--lexical position)))
            (setq role lexical recovered t)))
        (unless role
          (let ((text (buffer-substring-no-properties (point-min) position)))
            (when (or (string-blank-p text)
                      (and (string-match-p "\n[ \t]*\\'" text)
                           leaf (not (treesit-node-check leaf 'has-error))))
              (setq role (if (eq language 'ocaml-interface) 'signature-item 'structure-item)))))
        (let ((result (list :role (or role 'unknown)
                            :confidence (cond ((not role) 'unknown) (recovered 'recovered) (t 'tree))
                            :language language
                            :bounds (and leaf (cons (treesit-node-start leaf) (treesit-node-end leaf))))))
          (setq ocaml-syntax-context-cache (cons key result)) result)))))

(defun ocaml-syntax-context-snippet-allowed-p (id &optional position)
  "Return whether snippet ID is allowed at POSITION."
  (if (not (derived-mode-p 'neocaml-base-mode)) t
    (let* ((context (ocaml-syntax-context-at position))
           (role (plist-get context :role)))
      (or (eq role 'unknown)
          (memq role (cdr (assoc id ocaml-syntax-context-snippet-roles)))))))

(defun ocaml-syntax-context-trigger-position ()
  "Return the start of the trigger ending at point."
  (save-excursion (skip-chars-backward "A-Za-z0-9_'[|({") (point)))

(defun ocaml-syntax-context-filter-entries (entries)
  "Filter snippet candidate ENTRIES by the insertion context."
  (seq-filter
   (lambda (entry)
     (let ((spec (seq-find (lambda (spec)
                            (equal (plist-get spec :name) (plist-get entry :name)))
                          my/ocaml-snippet-registry)))
       (or (null spec) (ocaml-syntax-context-snippet-allowed-p
                       (plist-get spec :id) (ocaml-syntax-context-trigger-position))))) entries))

(defun ocaml-syntax-context-guard-trigger (original &rest args)
  "Filter the direct trigger returned by ORIGINAL with ARGS."
  (when-let* ((result (apply original args)))
    (let* ((action (plist-get result :action))
           (spec (seq-find (lambda (s) (eq action (plist-get s :command)))
                           my/ocaml-snippet-registry)))
      (when (or (null spec) (ocaml-syntax-context-snippet-allowed-p
                            (plist-get spec :id) (car (plist-get result :bounds)))) result))))

(defun ocaml-syntax-context-guard-command (id original &rest args)
  "Call ORIGINAL with ARGS only when snippet ID is applicable."
  (unless (ocaml-syntax-context-snippet-allowed-p id (ocaml-syntax-context-trigger-position))
    (user-error "Snippet %s is unavailable in this syntax position" id))
  (apply original args))

(defun ocaml-syntax-context-integrate ()
  "Attach shared syntax conditions to the existing OCaml snippet registry."
  (advice-add 'my/type-completion-snippet-entries :filter-return #'ocaml-syntax-context-filter-entries)
  (advice-add 'my/ocaml-direct-trigger :around #'ocaml-syntax-context-guard-trigger)
  (with-eval-after-load 'yasnippet
    (dolist (spec my/ocaml-snippet-registry)
      (let ((id (plist-get spec :id)) (template (plist-get spec :template)))
        (when template
          (yas-define-snippets
           'neocaml-base-mode
           (list (list id template id
                       `(ocaml-syntax-context-snippet-allowed-p
                         ,id (ocaml-syntax-context-trigger-position))))))
        (when-let* ((command (plist-get spec :command)))
          (advice-add command :around
                      (apply-partially #'ocaml-syntax-context-guard-command id)
                      `((name . ,(intern (concat "ocaml-context-" id))))))))))

(provide 'ocaml-syntax-context)

;;; structural-tests.el --- Structural editing regression tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'combobulate-extension)
(require 'ocaml-syntax-context)
(require 'neocaml)

(defmacro structural-test-buffer (language text &rest body)
  (declare (indent 2))
  `(with-temp-buffer
     (let ((transient-mark-mode t))
       (insert ,text)
       (treesit-parser-create ,language)
       (goto-char (point-min))
       ,@body)))

(ert-deftest structural-core-does-not-load-meow ()
  (should-not (featurep 'meow)))

(ert-deftest structural-class-queries-across-languages ()
  (dolist (spec '((json "[\"a\", \"long\", [\"nested\"]]" 3)
                  (python "f('a', 'long')\n" 2)
                  (typescript "f(\"a\", \"long\");" 2)
                  (ocaml "let x = [\"a\"; \"long\"]" 2)))
    (structural-test-buffer (car spec) (cadr spec)
      (should (= (nth 2 spec) (length (combobulate-extension-query
                                      'strings (cons (point-min) (point-max)))))))))

(ert-deftest structural-nested-calls-are-disjoint ()
  (structural-test-buffer 'python "f(g(x))\nh(y)"
    (let ((scope (cons (point-min) (point-max))))
      (should (equal '("f(g(x))" "h(y)")
                     (mapcar (lambda (r) (buffer-substring-no-properties
                                         (plist-get r :beg) (plist-get r :end)))
                             (combobulate-extension-query 'calls scope))))
      (should (equal '("g(x)" "h(y)")
                     (mapcar (lambda (r) (buffer-substring-no-properties
                                         (plist-get r :beg) (plist-get r :end)))
                             (combobulate-extension-query 'calls scope t)))))))

(ert-deftest structural-batch-variable-length-and-undo ()
  (structural-test-buffer 'json "[\"a\", \"long\"]"
    (buffer-enable-undo)
    (combobulate-extension-set-targets
     (combobulate-extension-query 'strings (cons (point-min) (point-max))))
    (combobulate-extension-apply-targets
     (lambda (beg end) (goto-char end) (insert "]") (goto-char beg) (insert "[")))
    (should (equal (buffer-string) "[[\"a\"], [\"long\"]]"))
    (undo)
    (should (equal (buffer-string) "[\"a\", \"long\"]"))))

(ert-deftest structural-stale-batch-is-rejected ()
  (structural-test-buffer 'json "[\"a\", \"b\"]"
    (combobulate-extension-set-targets
     (combobulate-extension-query 'strings (cons (point-min) (point-max))))
    (goto-char 3) (insert "changed")
    (let ((before (buffer-string)))
      (should-error (combobulate-extension-apply-targets #'delete-region) :type 'user-error)
      (should (equal before (buffer-string))))))

(ert-deftest structural-error-elsewhere-does-not-hide-strings ()
  (structural-test-buffer 'ocaml "let x = \"intact\"\nlet y ="
    (should (= 1 (length (combobulate-extension-query
                          'strings (cons (point-min) (point-max))))))))

(ert-deftest structural-selection-history ()
  (structural-test-buffer 'json "[1, 2]"
    (goto-char 2)
    (combobulate-extension-select-node-dwim)
    (should (equal (cons (region-beginning) (region-end)) '(2 . 3)))
    (combobulate-extension-expand-selection)
    (should (equal (cons (region-beginning) (region-end)) '(1 . 7)))
    (combobulate-extension-contract-selection)
    (should (equal (cons (region-beginning) (region-end)) '(2 . 3)))))

(ert-deftest ocaml-incomplete-slots ()
  (dolist (spec '(("let x = " expression) ("let x : " type)
                  ("module M = " module-expression) ("module M : " module-type)
                  ("module type S = " module-type) ("let " pattern)
                  ("type " name) ("type t = " type) ("" structure-item)))
    (with-temp-buffer
      (neocaml-mode)
      (insert (car spec))
      (should (eq (cadr spec) (plist-get (ocaml-syntax-context-at) :role))))))

(ert-deftest ocaml-interface-slots ()
  (dolist (spec '(("" signature-item) ("val x : " type)
                  ("module M : sig\n" signature-item)))
    (with-temp-buffer
      (neocaml-interface-mode) (insert (car spec))
      (should (eq (cadr spec) (plist-get (ocaml-syntax-context-at) :role))))))

(ert-deftest ocaml-snippet-eligibility ()
  (with-temp-buffer
    (neocaml-mode) (insert "let x = ")
    (should (ocaml-syntax-context-snippet-allowed-p "if"))
    (should-not (ocaml-syntax-context-snippet-allowed-p "module"))
    (erase-buffer) (insert "val x : ")
    (should-not (ocaml-syntax-context-snippet-allowed-p "if"))))

(ert-deftest ocaml-incremental-tuples-recover ()
  (structural-test-buffer 'ocaml "let x = (1, "
    (goto-char (point-max))
    (should (string-match-p "ERROR" (treesit-node-string (treesit-buffer-root-node 'ocaml))))
    (insert "2")
    (should (string-match-p "tuple_expression" (treesit-node-string (treesit-buffer-root-node 'ocaml))))
    (delete-char -1)
    (should (string-match-p "ERROR" (treesit-node-string (treesit-buffer-root-node 'ocaml))))))

(ert-deftest structural-children-and-narrowing ()
  (structural-test-buffer 'json "[1, 2, [3]]"
    (let ((targets (combobulate-extension-query 'children (cons 1 (point-max)))))
      (should (= 3 (length targets))))
    (narrow-to-region 8 11)
    (goto-char (point-min))
    (should (= 1 (length (combobulate-extension-query 'children))))))

(ert-deftest structural-envelope-wrap-and-cancel ()
  (structural-test-buffer 'ocaml "let x = f y"
    (setq major-mode 'neocaml-mode)
    (combobulate-extension-enable)
    (goto-char 9)
    (push-mark (point-max) t t)
    (combobulate-extension-wrap-dwim '(:name "paren" :template ("(" r ")")))
    (should (equal "let x = (f y)" (buffer-string)))
    (goto-char 10) (push-mark 12 t t)
    (should-error (combobulate-extension-wrap-dwim '(:name "paren" :template ("(" r ")")))
                  :type 'user-error)))

(ert-deftest ocaml-finished-definition-and-comment-context ()
  (with-temp-buffer
    (neocaml-mode) (insert "let x = 1\n")
    (should (eq 'structure-item (plist-get (ocaml-syntax-context-at) :role)))
    (insert "(* module M = ")
    (should-not (ocaml-syntax-context-snippet-allowed-p "module"))))

;;; interview.el --- interview session and tutor scratchpad layouts  -*- lexical-binding: t; -*-

(defun interview--showing-p (file)
  (seq-some (lambda (window)
              (when-let* ((name (buffer-file-name (window-buffer window))))
                (file-equal-p name file)))
            (window-list (selected-frame) 'no-minibuf)))

(defun interview--layout (file side)
  (unless (interview--showing-p file)
    (delete-other-windows)
    (find-file file)
    (let ((main (selected-window))
          (buffer (funcall side)))
      (when buffer
        (set-window-buffer (split-window-right) buffer))
      (select-window main))))

(defun interview--graphical-frame ()
  (if (window-system (selected-frame))
      (selected-frame)
    (seq-find (lambda (frame) (and (window-system frame) (frame-visible-p frame)))
              (frame-list))))

(defun interview-compile (dir command)
  (when-let* ((frame (interview--graphical-frame)))
    (select-frame-set-input-focus frame))
  (let ((default-directory (file-name-as-directory dir))
        (compilation-buffer-name-function (lambda (_) "*interview tests*")))
    (compile command)))

(defun interview-open-session (prompt main)
  (when-let* ((frame (interview--graphical-frame)))
    (select-frame-set-input-focus frame))
  (interview--layout main (lambda () (find-file-noselect prompt))))

(defconst interview-tutor-langs
  `(("ocaml"
     :main "scratch.ml"
     :files (("dune-project" . "(lang dune 3.0)\n")
             ("dune" . "(executable\n (name scratch))\n")
             ("scratch.ml" . ""))
     :repl ,(lambda () (save-window-excursion (neocaml-repl-switch-to-repl) (current-buffer))))
    ("python"
     :main "scratch.py"
     :files (("scratch.py" . ""))
     :repl ,(lambda () (process-buffer (run-python nil nil nil))))
    ("rust"
     :main "src/main.rs"
     :files (("Cargo.toml" . "[package]\nname = \"scratch\"\nversion = \"0.1.0\"\nedition = \"2024\"\n\n[dependencies]\n")
             ("src/main.rs" . "fn main() {\n}\n"))
     :compile "cargo run"
     :repl ,(lambda () (make-comint "evcxr" "evcxr")))
    ("c"
     :main "scratch.c"
     :files (("compile_flags.txt" . "-std=c17\n-Wall\n-Wextra\n")
             ("scratch.c" . "#include <stdio.h>\n\nint main(void) {\n    return 0;\n}\n"))
     :compile "cc -std=c17 -Wall -Wextra -g scratch.c -o scratch && ./scratch")
    ("csharp"
     :main "Program.cs"
     :files (("Scratch.csproj" . "<Project Sdk=\"Microsoft.NET.Sdk\">\n  <PropertyGroup>\n    <OutputType>Exe</OutputType>\n    <TargetFramework>net8.0</TargetFramework>\n    <ImplicitUsings>enable</ImplicitUsings>\n    <Nullable>enable</Nullable>\n  </PropertyGroup>\n</Project>\n")
             ("Program.cs" . ""))
     :compile "dotnet run")))

(defun interview-tutor-scratch (lang root)
  (let* ((spec (or (cdr (assoc lang interview-tutor-langs))
                   (list :main "scratch.txt" :files '(("scratch.txt" . "")))))
         (dir (file-name-as-directory (expand-file-name (if (assoc lang interview-tutor-langs) lang "text") root)))
         (main (expand-file-name (plist-get spec :main) dir)))
    (pcase-dolist (`(,name . ,text) (plist-get spec :files))
      (let ((file (expand-file-name name dir)))
        (unless (file-exists-p file)
          (make-directory (file-name-directory file) t)
          (write-region text nil file nil 'silent))))
    (when-let* ((command (plist-get spec :compile)))
      (with-current-buffer (find-file-noselect main)
        (setq-local compile-command command)))
    (interview--layout
     main
     (lambda ()
       (when-let* ((repl (plist-get spec :repl)))
         (condition-case err
             (funcall repl)
           (error (message "interview: no %s REPL: %s" lang (error-message-string err)) nil)))))))

(provide 'interview)

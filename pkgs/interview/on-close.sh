# interview close hook: close the finished interview's interviewer window and its Emacs buffers.
dir=${1:?session directory}
sleep 3
elisp() { printf '"%s"' "$(printf %s "$1" | sed 's/[\\"]/\\&/g')"; }
timeout 10 emacsclient --eval "(let ((kill-buffer-query-functions nil))
  (dolist (b (buffer-list))
    (let ((f (or (buffer-file-name b) (buffer-local-value 'dired-directory b))))
      (when (and (stringp f) (string-prefix-p $(elisp "$dir/") (expand-file-name f)))
        (with-current-buffer b (set-buffer-modified-p nil))
        (kill-buffer b)))))" >/dev/null 2>&1 || true
systemctl --user stop interview-claude.service 2>/dev/null || true
hyprctl clients -j | jq -r '.[] | select(.class == "interview-claude") | .pid' | xargs -r kill || true

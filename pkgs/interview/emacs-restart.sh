# interview Emacs restart: restart the main daemon (or, with tutor, the tutor daemon) and reopen its frame.
if [ "${1:-main}" = tutor ]; then
  timeout 30 systemctl --user restart interview-tutor-emacs.service || systemctl --user kill --signal=KILL interview-tutor-emacs.service || true
  exec interview-tutor-emacs-frame
fi
if ! timeout 30 systemctl --user restart emacs.service; then
  systemctl --user kill --signal=KILL emacs.service || true
  timeout 60 systemctl --user restart emacs.service || true
fi
exec interview-emacs-frame

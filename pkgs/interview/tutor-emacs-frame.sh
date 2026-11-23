# tutor Emacs frame: start the sandboxed tutor daemon if needed and open one frame of it.
socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/interview-tutor-emacs/server"
open() { timeout 10 emacsclient -s "$socket" -c -n >/dev/null 2>&1; }
if timeout 180 systemctl --user start interview-tutor-emacs.service && open; then
  exit 0
fi
timeout 30 systemctl --user restart interview-tutor-emacs.service || systemctl --user kill --signal=KILL interview-tutor-emacs.service || true
if timeout 180 systemctl --user start interview-tutor-emacs.service && open; then
  exit 0
fi
notify-send --urgency=critical "Tutor Emacs did not open" \
  "journalctl --user -u interview-tutor-emacs shows why. SUPER+CTRL+ALT+R retries."
exit 1

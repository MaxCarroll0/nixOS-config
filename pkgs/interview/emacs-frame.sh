# interview Emacs frame: open a frame (or, with --reuse, files in the current one) on the main daemon, restarting it when it does not answer.
frame=(-c)
if [ "${1:-}" = --reuse ]; then
  frame=()
  shift
fi
alive() { timeout 3 emacsclient --eval t >/dev/null 2>&1; }
open() { timeout 10 emacsclient "${frame[@]}" -n "$@" >/dev/null 2>&1; }
if alive && open "$@"; then
  exit 0
fi
if ! timeout 30 systemctl --user restart emacs.service; then
  systemctl --user kill --signal=KILL emacs.service || true
  timeout 60 systemctl --user restart emacs.service || true
fi
for _ in $(seq 30); do
  alive && break
  sleep 1
done
frame=(-c)
if open "$@"; then
  exit 0
fi
notify-send --urgency=critical "Interview Emacs did not open" \
  "The Emacs daemon did not answer even after a restart. SUPER+CTRL+ALT+R restarts it again."
exit 1

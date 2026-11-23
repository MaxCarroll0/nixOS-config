# tutor Emacs frame: start the sandboxed tutor daemon if needed and show a scratchpad in the session's language beside its REPL, in a new frame unless one is open.
socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/interview-tutor-emacs/server"
elisp() { printf '"%s"' "$(printf %s "$1" | sed 's/[\\"]/\\&/g')"; }
lang=$(interview status --json | jq -r '.lang // "text"')
show="(progn (load $(elisp "$INTERVIEW_EL") nil t) (interview-tutor-scratch $(elisp "$lang") $(elisp "$TUTOR_SCRATCH")))"
frame=(-c)
if hyprctl clients -j | jq -e 'any(.[]; .class == "interview-tutor-emacs")' >/dev/null; then
  frame=()
fi
open() { timeout 30 emacsclient -s "$socket" "${frame[@]}" -n --eval "$show" >/dev/null 2>&1; }
if timeout 180 systemctl --user start interview-tutor-emacs.service && open; then
  exit 0
fi
timeout 30 systemctl --user restart interview-tutor-emacs.service || systemctl --user kill --signal=KILL interview-tutor-emacs.service || true
frame=(-c)
if timeout 180 systemctl --user start interview-tutor-emacs.service && open; then
  exit 0
fi
notify-send --urgency=critical "Tutor Emacs did not open" \
  "journalctl --user -u interview-tutor-emacs shows why. SUPER+CTRL+ALT+R retries."
exit 1

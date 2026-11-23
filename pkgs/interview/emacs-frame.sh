# interview Emacs frame: show the session's prompt and solution on the main daemon (in the existing frame with --reuse), restarting it when it does not answer.
frame=(-c)
if [ "${1:-}" = --reuse ]; then
  frame=()
  shift
fi
elisp() { printf '"%s"' "$(printf %s "$1" | sed 's/[\\"]/\\&/g')"; }
if [ $# -ge 2 ]; then
  prompt=$1 main=$2
else
  status=$(interview status --json)
  prompt=$(jq -r 'select(.phase != "idle") | .dir + "/PROMPT.md"' <<<"$status")
  main=$(jq -r 'select(.phase != "idle") | .main // empty' <<<"$status")
fi
show=()
if [ -n "$main" ]; then
  show=(--eval "(progn (load $(elisp "$INTERVIEW_EL") nil t) (interview-open-session $(elisp "$prompt") $(elisp "$main")))")
fi
alive() { timeout 3 emacsclient --eval t >/dev/null 2>&1; }
open() {
  if [ ${#frame[@]} -eq 0 ] && [ ${#show[@]} -eq 0 ]; then
    return 0
  fi
  timeout 10 emacsclient "${frame[@]}" -n "${show[@]}" >/dev/null 2>&1
}
if alive && open; then
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
if open; then
  exit 0
fi
notify-send --urgency=critical "Interview Emacs did not open" \
  "The Emacs daemon did not answer even after a restart. SUPER+CTRL+ALT+R restarts it again."
exit 1

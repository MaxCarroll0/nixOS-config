# interview start hook: start a fresh interviewer, stop the previous language's tutor Emacs, and open the new session's files in Emacs.
hyprctl clients -j | jq -r '.[] | select(.class == "interview-claude") | .pid' | xargs -r kill || true
systemctl --user stop interview-claude.service interview-tutor-emacs.service 2>/dev/null || true
systemd-run --user --collect --quiet --unit=interview-claude \
  --working-directory="$INTERVIEW_REPO" \
  kitty --class interview-claude --title interviewer claude "/interview"
if hyprctl clients -j | jq -e 'any(.[]; .class == "emacs")' >/dev/null; then
  interview-emacs-frame --reuse "$@" || true
else
  interview-emacs-frame "$@" || true
fi

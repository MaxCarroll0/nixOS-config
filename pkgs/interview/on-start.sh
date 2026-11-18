# interview start hook: open the new session's files in Emacs and start a fresh interviewer.
hyprctl clients -j | jq -r '.[] | select(.class == "interview-claude") | .pid' | xargs -r kill || true
if hyprctl clients -j | jq -e 'any(.[]; .class == "emacs")' >/dev/null; then
  emacsclient -n "$@" || true
else
  emacsclient -c -n "$@" || true
fi
systemd-run --user --collect --quiet --unit="interview-claude-$(date +%s)" \
  --working-directory="$INTERVIEW_REPO" \
  kitty --class interview-claude --title interviewer claude "/interview"

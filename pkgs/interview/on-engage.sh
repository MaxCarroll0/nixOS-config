# interview lockdown engage hook: open an Emacs frame on the interview workspace, and the interviewer while an interview runs.
on_workspace() {
  hyprctl clients -j | jq -e --arg class "$1" --arg ws "$INTERVIEW_WORKSPACE" \
    'any(.[]; .class == $class and .workspace.name == $ws)' >/dev/null
}
if ! on_workspace emacs; then
  timeout 10 emacsclient -c -n || true
fi
if [ "$(interview status --json | jq -r .phase)" != idle ] && ! on_workspace interview-claude; then
  systemd-run --user --collect --quiet --unit="interview-claude-$(date +%s)" \
    --working-directory="$INTERVIEW_REPO" \
    kitty --class interview-claude --title interviewer claude "/interview"
fi

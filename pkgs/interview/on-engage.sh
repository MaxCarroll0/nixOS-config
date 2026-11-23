# interview lockdown engage hook: open the interviewer while an interview runs, and an Emacs frame on the interview workspace.
present() {
  hyprctl clients -j | jq -e --arg class "$1" --arg ws "$INTERVIEW_WORKSPACE" \
    'any(.[]; .class == $class and (.workspace.name == $ws or .workspace.name == "special:lockdown"))' >/dev/null
}
if [ "$(interview status --json | jq -r .phase)" != idle ] && ! present interview-claude; then
  systemd-run --user --collect --quiet --unit="interview-claude-$(date +%s)" \
    --working-directory="$INTERVIEW_REPO" \
    kitty --class interview-claude --title interviewer claude "/interview"
fi
if ! present emacs; then
  interview-emacs-frame || true
fi

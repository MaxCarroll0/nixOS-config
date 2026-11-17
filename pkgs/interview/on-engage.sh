# interview lockdown engage hook: open the Emacs frame and the interviewer session.
if ! hyprctl clients -j | jq -e 'any(.[]; .class == "emacs")' >/dev/null; then
  emacsclient -c -n || true
fi
if ! hyprctl clients -j | jq -e 'any(.[]; .class == "interview-claude")' >/dev/null; then
  cd "$INTERVIEW_REPO"
  setsid -f kitty --class interview-claude --title "interviewer" claude "/interview"
fi

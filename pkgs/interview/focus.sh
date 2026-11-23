# interview focus hook: bring the running interviewer's window to the front; it never starts one.
if hyprctl clients -j | jq -e 'any(.[]; .class == "interview-claude")' >/dev/null; then
  hyprctl dispatch 'hl.dsp.focus({ window = "class:^(interview-claude)$" })' >/dev/null
else
  notify-send --app-name=interview "No interviewer window" "Start next launches one with the interview."
fi

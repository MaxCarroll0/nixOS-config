# interview pause hook: hide the session behind the lockdown and show the tutor window.
lockdown state interview paused || true
if hyprctl clients -j | jq -e 'any(.[]; .class == "interview-tutor")' >/dev/null; then
  exit 0
fi
cd "$INTERVIEW_REPO/tutor"
exec kitty --class interview-tutor --title "tutor" claude "/tutor"

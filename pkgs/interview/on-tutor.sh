# interview tutor hook: show the tutor Claude window and the sandboxed tutor Emacs on its scratchpad.
if ! hyprctl clients -j | jq -e 'any(.[]; .class == "interview-tutor")' >/dev/null; then
  systemd-run --user --collect --quiet --unit="interview-tutor-$(date +%s)" \
    --working-directory="$INTERVIEW_REPO/tutor" \
    kitty --class interview-tutor --title tutor claude "/tutor"
fi
interview-tutor-emacs-frame

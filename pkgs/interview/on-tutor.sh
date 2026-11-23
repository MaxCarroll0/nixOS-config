# interview tutor hook: show the tutor Claude window and a frame of the sandboxed tutor Emacs.
has() {
  hyprctl clients -j | jq -e --arg class "$1" 'any(.[]; .class == $class)' >/dev/null
}
if ! has interview-tutor; then
  systemd-run --user --collect --quiet --unit="interview-tutor-$(date +%s)" \
    --working-directory="$INTERVIEW_REPO/tutor" \
    kitty --class interview-tutor --title tutor claude "/tutor"
fi
if ! has interview-tutor-emacs; then
  interview-tutor-emacs-frame
fi

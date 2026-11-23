# tutor Emacs: a separate daemon in the interview dev shell, with its own app-id, socket and state.
dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/interview-tutor-emacs"
. "$dir/dev-env.sh"
export XDG_STATE_HOME="$TUTOR_EMACS_STATE"
cd "$TUTOR_EMACS_STATE" || exit 1
exec "$TUTOR_EMACS" --fg-daemon="$dir/server" --init-directory="$TUTOR_EMACS_STATE" \
  --eval '(setq x-resource-name "interview-tutor-emacs")'

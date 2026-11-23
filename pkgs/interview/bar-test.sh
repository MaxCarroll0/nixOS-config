# interview bar test hook: run the visible tests, or submit, in a compilation buffer in the interview Emacs.
mode=${1:?run or submit}
dir=$(interview status --json | jq -r 'select(.phase != "idle") | .dir')
if [ -z "$dir" ]; then
  notify-send --app-name=interview "No interview running" "Start next begins one."
  exit 1
fi
elisp() { printf '"%s"' "$(printf %s "$1" | sed 's/[\\"]/\\&/g')"; }
command="$(command -v interview) $mode"
if ! timeout 10 emacsclient --eval "(progn (load $(elisp "$INTERVIEW_EL") nil t) (interview-compile $(elisp "$dir") $(elisp "$command")))" >/dev/null 2>&1; then
  notify-send --urgency=critical --app-name=interview "Interview Emacs did not answer" "SUPER+F6 reopens it; \`interview $mode\` works in a terminal too."
fi

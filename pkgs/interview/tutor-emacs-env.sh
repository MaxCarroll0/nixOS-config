# tutor Emacs environment: the current interview language's dev shell as a sourced script, written outside the sandbox before the daemon starts.
dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/interview-tutor-emacs"
mkdir -p "$dir" "$TUTOR_EMACS_STATE"
lang=$(interview status --json | jq -r '.lang // empty') || lang=
ref=$INTERVIEW_REPO
if [ -n "$lang" ] && [ -f "$INTERVIEW_REPO/langs/$lang/shell.nix" ]; then
  ref="$INTERVIEW_REPO#$lang"
fi
if timeout 120 nix print-dev-env "$ref" >"$dir/dev-env.sh.new"; then
  mv "$dir/dev-env.sh.new" "$dir/dev-env.sh"
else
  echo "tutor-emacs-env: no dev shell for $ref, the REPLs fall back to the user profile" >&2
  : >"$dir/dev-env.sh"
fi

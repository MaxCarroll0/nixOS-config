# tutor Emacs environment: the interview repo's dev shell as a sourced script, written outside the sandbox before the daemon starts.
dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/interview-tutor-emacs"
mkdir -p "$dir" "$TUTOR_EMACS_STATE"
if timeout 120 nix print-dev-env "$INTERVIEW_REPO" >"$dir/dev-env.sh.new"; then
  mv "$dir/dev-env.sh.new" "$dir/dev-env.sh"
else
  echo "tutor-emacs-env: no dev shell, the REPLs fall back to the user profile" >&2
  : >"$dir/dev-env.sh"
fi

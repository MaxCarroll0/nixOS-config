# interview resume hook: return the lockdown to the interview and show the session files in its Emacs.
lockdown state interview active || true
if hyprctl clients -j | jq -e 'any(.[]; .class == "emacs")' >/dev/null; then
  interview-emacs-frame --reuse || true
else
  interview-emacs-frame || true
fi

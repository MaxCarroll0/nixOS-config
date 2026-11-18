toplevel() {
  local p
  p=$(readlink -f "$1")
  [ -e "$p/deploy-rs-activate" ] && p=$(dirname "$(readlink "$p/activate")")
  echo "$p"
}

staged=$(toplevel /nix/var/nix/profiles/system)
[ "$staged" != "$(toplevel /run/current-system)" ] || exit 0

graphical_session_open() {
  local session props
  for session in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
    props=$(loginctl show-session "$session" -p Type -p Class -p State 2>/dev/null) || continue
    grep -qx 'Class=user' <<<"$props" \
      && grep -qE '^Type=(wayland|x11)$' <<<"$props" \
      && ! grep -qx 'State=closing' <<<"$props" \
      && return 0
  done
  return 1
}

for _ in $(seq 1 30); do
  graphical_session_open || break
  sleep 2
done
if graphical_session_open; then
  echo "a graphical session is open; the staged system waits for the next logout or boot"
  exit 0
fi

echo "no graphical session; switching to the staged $staged"
"$staged/bin/switch-to-configuration" switch

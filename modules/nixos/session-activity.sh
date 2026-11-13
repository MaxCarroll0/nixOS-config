resident=$(systemctl show -p MainPID --value nix-daemon.service 2>/dev/null || echo 0)
for pid in $(pgrep -x nix-daemon || true); do
  if [ "$pid" != "$resident" ]; then
    exit 0
  fi
done

if [ "$resident" != 0 ] && pgrep -P "$resident" >/dev/null 2>&1; then
  exit 0
fi

if pgrep -f "[.]tailscaled-wrapped be-child ssh" >/dev/null 2>&1; then
  exit 0
fi

threshold=$(( $(date +%s) - @idleSeconds@ ))
for pty in /dev/pts/*; do
  [ -c "$pty" ] || continue
  case "$pty" in
    */ptmx) continue ;;
  esac
  atime=$(stat -c %X "$pty" 2>/dev/null || echo 0)
  if [ "$atime" -gt "$threshold" ]; then
    exit 0
  fi
done

# Seatless sessions are skipped because tailscaled registers one per SSH
# command, each of them type tty and never idle.
for session in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
  [ "$(loginctl show-session "$session" -p Class --value)" = user ] || continue
  [ -n "$(loginctl show-session "$session" -p Seat --value)" ] || continue

  # IdleHint is never set under Wayland; the screen lock is, by KDE.
  if [ "$(loginctl show-session "$session" -p Type --value)" = tty ]; then
    if [ "$(loginctl show-session "$session" -p IdleHint --value)" != yes ]; then
      exit 0
    fi
    continue
  fi

  if [ "$(loginctl show-session "$session" -p LockedHint --value)" != yes ]; then
    exit 0
  fi
done

exit 1

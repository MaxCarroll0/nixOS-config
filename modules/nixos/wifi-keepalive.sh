while :; do
  gw=$(ip -4 route show dev "$IFACE" default | awk '{ print $3; exit }')
  if [ -n "$gw" ]; then
    ping -q -I "$IFACE" -i 0.2 -W 1 -c 50 "$gw" >/dev/null || sleep 1
  else
    sleep 5
  fi
done

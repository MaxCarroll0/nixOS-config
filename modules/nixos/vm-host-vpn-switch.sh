if [ "${VPN_SWITCH_NS:-}" != "1" ]; then
  export VPN_SWITCH_NS=1
  exec unshare --mount --propagation private -- "$0" "$@"
fi
mount --bind @bypassResolvConf@ /etc/resolv.conf

bootstrap=""
if [ "${1:-}" = "--bootstrap" ]; then
  bootstrap="$2"
fi

PROTONVPN_USERNAME="$(cat @usernameFile@)"
PROTONVPN_PASSWORD="$(cat @passwordFile@)"
export PROTONVPN_USERNAME PROTONVPN_PASSWORD

rundir="$(mktemp -d -p /run mc-server-vpn.XXXXXX)"
chmod 700 "$rundir"
trap 'rm -rf "$rundir"' EXIT

confgen() {
  setpriv --regid @novpnGid@ --clear-groups protonvpn-wg "$@"
}

current=""
if [ -z "$bootstrap" ]; then
  current="$(wg show @interface@ endpoints | awk 'NR == 1 { sub(/:[0-9]+$/, "", $2); print $2 }')"
fi
recent="$(cat @stateDir@/recent 2>/dev/null || true)"

names="$(
  confgen -list-servers -countries @country@ -no-session -p2p-only=false \
    | awk -v country=@country@ -v city=@city@ '
        $1 == country && $3 == city && match($0, / [0-9]+% /) {
          print substr($0, RSTART + 1, RLENGTH - 3), $2
        }' \
    | sort -n | awk 'NR <= @pool@ { print $2 }' | shuf
)"
if [ -z "$names" ]; then
  echo "no @city@ servers listed" >&2
  exit 1
fi

render() {
  awk '
    /^DNS *=/ { next }
    /^Address *=/ { print "Address = @localAddress@/32"; next }
    { print }
    /^\[Interface\]/ { print "Table = off"; print "FwMark = @fwmark@" }
  ' "$1"
}

healthy() {
  local since="$1" latest
  for _ in $(seq 1 20); do
    latest="$(wg show @interface@ latest-handshakes | awk '{ print $2 }' | sort -n | tail -1)"
    if [ "${latest:-0}" -ge "$since" ] && ping -c 1 -W 2 -I @interface@ @healthProbe@ >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

publish() {
  jq -cn --arg server "$1" --arg city @city@ --arg entry "$2" --argjson switched "$(date +%s)" \
    '$ARGS.named' > @statusFile@.tmp
  mv @statusFile@.tmp @statusFile@
  { printf '%s\n' "$2"; printf '%s\n' "$recent" | grep -vx "$2" | head -n 3; } | grep -v '^$' > @stateDir@/recent || true
}

activate() {
  local name="$1" entry="$2" conf="$3"
  if [ -n "$bootstrap" ]; then
    install -d -m 700 "$(dirname "$bootstrap")"
    render "$conf" > "$bootstrap"
    chmod 600 "$bootstrap"
    publish "$name" "$entry"
    echo "bootstrap -> $name ($entry)"
    return 0
  fi
  local backup="$rundir/backup.conf" live="$rundir/live.conf" started
  wg showconf @interface@ > "$backup"
  render "$conf" > "$live"
  started="$(date +%s)"
  wg syncconf @interface@ <(wg-quick strip "$live")
  if healthy "$started"; then
    publish "$name" "$entry"
    echo "@interface@ -> $name ($entry)"
    return 0
  fi
  wg syncconf @interface@ "$backup"
  echo "$name ($entry) did not come up; restored previous peer" >&2
  return 1
}

attempts=0
fallback=""
for name in $names; do
  [ "$attempts" -lt @maxAttempts@ ] || break
  attempts=$((attempts + 1))
  conf="$rundir/$attempts.conf"
  confgen -server "$name" -no-session -no-save -moderate-nat -output "$conf" >/dev/null 2>&1 || continue
  entry="$(sed -n 's/^# - Entry IP: //p' "$conf")"
  [ "$(sed -n 's/^# - City: //p' "$conf")" = @city@ ] || continue
  [ -n "$entry" ] && [ "$entry" != "$current" ] || continue
  if printf '%s\n' "$recent" | grep -qx "$entry"; then
    [ -n "$fallback" ] || fallback="$name $entry $conf"
    continue
  fi
  activate "$name" "$entry" "$conf" && exit 0
done

if [ -n "$fallback" ]; then
  read -r name entry conf <<<"$fallback"
  activate "$name" "$entry" "$conf" && exit 0
fi

echo "no other @city@ server came up" >&2
exit 1

usage() {
  printf '%s\n' \
    'vpn-switch - pick a Proton server and apply it to the live tunnel' \
    "" \
    'usage:' \
    '  vpn-switch                    re-pick per the configured policy' \
    '  vpn-switch --country XX[,YY]  override the country for this switch' \
    '  vpn-switch --server NAME      use one exact server, e.g. UK#42' \
    '  vpn-switch --secure-core      restrict to Secure Core servers' \
    '  vpn-switch --no-secure-core   allow ordinary servers' \
    '  vpn-switch --p2p|--no-p2p     require or ignore P2P support' \
    '  vpn-switch --list             show candidate servers and exit' \
    '  vpn-switch --status           show the current peer and handshake' \
    '  vpn-switch --disable          route all traffic around the tunnel' \
    '  vpn-switch --enable           restore tunnel routing' \
    '  vpn-switch --bootstrap FILE   write a config for wg-quick, do not apply' \
    '  vpn-switch --help             this text' \
    "" \
    'The peer is swapped on the running interface, so no unit is restarted.' \
    'On failure the previous peer is restored.' \
    "" \
    '--disable sends traffic out the physical link in the clear, with no' \
    'kill switch in front of it. It lasts until --enable or the next reboot.'
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi

if [ "${VPN_SWITCH_NS:-}" != "1" ]; then
  export VPN_SWITCH_NS=1
  exec unshare --mount --propagation private -- "$0" "$@"
fi
mount --bind @bypassResolvConf@ /etc/resolv.conf

countries="@countries@"
pool="@pool@"
server=""
status=0
bootstrap=""
list=0
disable=0
enable=0
secure=@secure@
p2p=@p2p@

while [ "$#" -gt 0 ]; do
  case "$1" in
    --country) countries="$2"; shift 2 ;;
    --server) server="$2"; shift 2 ;;
    --bootstrap) bootstrap="$2"; shift 2 ;;
    --status) status=1; shift ;;
    --list) list=1; shift ;;
    --disable) disable=1; shift ;;
    --enable) enable=1; shift ;;
    --secure-core) secure=true; shift ;;
    --no-secure-core) secure=false; shift ;;
    --p2p) p2p=true; shift ;;
    --no-p2p) p2p=false; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done

selectFlags=(-no-session "-p2p-only=$p2p")
if [ "$secure" = true ]; then
  selectFlags+=(-secure-core)
fi

vpnDisabled() {
  nft list table inet @disableTable@ >/dev/null 2>&1
}

if [ "$disable" -eq 1 ] && [ "$enable" -eq 1 ]; then
  echo "--disable and --enable are mutually exclusive" >&2
  exit 2
fi

if [ "$disable" -eq 1 ]; then
  if vpnDisabled; then
    echo "vpn already disabled"
    exit 0
  fi
  nft -f @disableRules@
  echo "vpn disabled: traffic leaves in the clear until --enable or reboot" >&2
  exit 0
fi

if [ "$enable" -eq 1 ]; then
  if vpnDisabled; then
    nft delete table inet @disableTable@
    echo "vpn enabled"
  else
    echo "vpn already enabled"
  fi
  exit 0
fi

iface=""
if [ -z "$bootstrap" ] && [ "$list" -eq 0 ]; then
  for _ in $(seq 1 30); do
    for candidate in $(wg show interfaces); do
      case "$candidate" in @interface@) iface="$candidate"; break ;; esac
    done
    [ -n "$iface" ] && break
    sleep 1
  done
  if [ -z "$iface" ]; then
    echo "no proton interface came up" >&2
    exit 1
  fi
fi

if [ "$status" -eq 1 ]; then
  if vpnDisabled; then
    echo "vpn: DISABLED, traffic is bypassing $iface"
  else
    echo "vpn: enabled"
  fi
  wg show "$iface"
  exit 0
fi

PROTONVPN_USERNAME="$(cat @usernameFile@)"
PROTONVPN_PASSWORD="$(cat @passwordFile@)"
export PROTONVPN_USERNAME PROTONVPN_PASSWORD

rundir="$(mktemp -d -p /run vpn-switch.XXXXXX)"
chmod 700 "$rundir"
trap 'rm -rf "$rundir"' EXIT

confgen() {
  setpriv --regid @novpnGid@ --clear-groups protonvpn-wg "$@"
}

backup="$rundir/backup.conf"
if [ -z "$bootstrap" ] && [ "$list" -eq 0 ]; then
  wg showconf "$iface" > "$backup"
  fwmark="$(wg show "$iface" fwmark)"
fi

healthy() {
  since="$1"
  echo "waiting for handshake" >&2
  for _ in $(seq 1 20); do
    latest="$(wg show "$iface" latest-handshakes | awk '{print $2}' | sort -n | tail -1)"
    if [ "${latest:-0}" -ge "$since" ] && ping -c 1 -W 2 @healthProbe@ >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

apply() {
  conf="$rundir/wg.conf"
  echo "generating config for $1" >&2
  confgen -server "$1" -no-save @moderateNat@-output "$conf" >/dev/null
  if [ -n "$bootstrap" ]; then
    install -D -m 600 "$conf" "$bootstrap"
    rm -f "$conf"
    return 0
  fi
  echo "applying $1" >&2
  started="$(date +%s)"
  wg syncconf "$iface" <(wg-quick strip "$conf")
  rm -f "$conf"
  if [ "$fwmark" != "off" ]; then
    wg set "$iface" fwmark "$fwmark"
  fi
  healthy "$started"
}

if [ -n "$server" ]; then
  if apply "$server"; then
    [ -n "$bootstrap" ] || printf '%s\n' "$server" > @serverFile@
    echo "${iface:-bootstrap} -> $server"
    exit 0
  fi
  wg syncconf "$iface" "$backup"
  echo "$server did not come up; restored previous peer" >&2
  exit 1
fi

echo "listing servers for $countries" >&2
candidates="$(
  confgen -list-servers -countries "$countries" "${selectFlags[@]}" \
    | awk '
        match($0, /[A-Z0-9-]+#[0-9]+/) {
          name = substr($0, RSTART, RLENGTH)
          if (match($0, /[0-9]+% +[0-9]+\.[0-9]+/)) {
            split(substr($0, RSTART, RLENGTH), f, /[% ]+/)
            print f[2], name
          }
        }' \
    | sort -n | awk -v pool="$pool" 'NR <= pool { print $2 }' | shuf
)"

if [ -z "$candidates" ]; then
  echo "no servers matched countries=$countries" >&2
  exit 1
fi

if [ "$list" -eq 1 ]; then
  echo "$candidates"
  exit 0
fi

for name in $candidates; do
  if apply "$name"; then
    [ -n "$bootstrap" ] || printf '%s\n' "$name" > @serverFile@
    echo "${iface:-bootstrap} -> $name"
    exit 0
  fi
  echo "$name did not come up, trying next" >&2
done

if [ -n "$bootstrap" ]; then
  echo "no candidate could be generated" >&2
  exit 1
fi

wg syncconf "$iface" "$backup"
echo "no candidate came up; restored previous peer" >&2
exit 1

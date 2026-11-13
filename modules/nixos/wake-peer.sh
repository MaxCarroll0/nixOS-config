sendOnly=0
if [ "${1:-}" = --send-only ]; then
  sendOnly=1
  shift
fi

host="${1:?usage: wake-peer [--send-only] <host>}"
probe() { nc -z -w 2 "$1" "$2" 2>/dev/null; }

mac=""; bcast=""; unlockPort=""; passFile=""; timeout=90
lanHost=""
case "$host" in
  @peers@
  *) ;;
esac

ready() {
  if [ -n "$lanHost" ] && ping -c 1 -W 1 "$lanHost" >/dev/null 2>&1; then
    return 0
  fi
  if tailscale ping -c 1 --timeout 2s --until-direct=false "$host" >/dev/null 2>&1; then
    return 0
  fi
  probe "$host" 22
}

send_magic() {
  [ -n "$mac" ] || return 0
  for target in $bcast $(ip -4 -oneline address show scope global \
        | grep -oE 'brd [0-9.]+' | cut -d ' ' -f 2 | sort -u) 255.255.255.255; do
    wol -i "$target" "$mac" >/dev/null 2>&1 || true
  done
}

relayDir="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/wake-peer"
relayHint="$relayDir/$host.relay"

# A relay on the wrong segment broadcasts harmlessly, so no host needs to know
# which LAN the sleeper is on.
delegate() {
  local sent=0 relay candidate hinted="" seen=""
  local -a candidates=()

  if [ -r "$relayHint" ]; then
    hinted="$(cat "$relayHint")"
    [ -n "$hinted" ] && candidates+=("$hinted")
  fi
  candidates+=(@relays@)

  for candidate in "${candidates[@]}"; do
    relay="${candidate#*=}"
    [ "${candidate%%=*}" = "$host" ] && continue
    case " $seen " in *" $relay "*) continue ;; esac
    seen="$seen $relay"

    tailscale ping -c 1 --timeout 3s --until-direct=false "$relay" >/dev/null 2>&1 || continue
    # Bounded: a relay still running a wake-peer without --send-only would
    # otherwise poll for a host named "--send-only" until its own deadline.
    if timeout 10 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
           "$relay" wake-peer --send-only "$host" >/dev/null 2>&1; then
      sent=1
      if [ "$relay" != "$hinted" ] && mkdir -p "$relayDir" 2>/dev/null; then
        printf '%s\n' "$relay" > "$relayHint" 2>/dev/null || true
      fi
    fi
  done

  [ "$sent" = 1 ]
}

if [ "$sendOnly" = 1 ]; then
  send_magic
  exit 0
fi

ready && exit 0

send_magic
delegate || true
resend=$(( $(date +%s) + 20 ))

deadline=$(( $(date +%s) + timeout ))

if [ -n "$passFile" ]; then
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if probe "$host" "$unlockPort"; then
      if [ -r "$passFile" ]; then
        ssh -p "$unlockPort" -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=5 "root@$host" < "$passFile" || true
      else
        echo "no passphrase at $passFile" >&2
      fi
      break
    fi
    sleep 2
  done
fi

while [ "$(date +%s)" -lt "$deadline" ]; do
  ready && exit 0
  if [ "$(date +%s)" -ge "$resend" ]; then
    send_magic
    delegate || true
    resend=$(( $(date +%s) + 20 ))
  fi
  sleep 0.5
done
exit 1

count() {
  local n
  n=$("$1") || n=0
  if [[ "$n" =~ ^[0-9]+$ ]]; then echo "$n"; else echo 0; fi
}

running=false
locks=0
logins=0
readyAt=0
run=$(@virsh@ domid @domainName@ 2>/dev/null) || run=-
case "$(@virsh@ domstate @domainName@)" in
  running | "in shutdown")
    running=true
    locks=$(count @guestLockCount@)
    logins=$(count @guestLoginCount@)
    readyAt=$(count @guestServerReadyAt@)
    ;;
esac

idle=false
[ "$running" = true ] && [ $((locks + logins)) -eq 0 ] && idle=true

if [ "$idle" = true ]; then
  systemctl is-active -q @idleCountdown@@"$run".timer @idleCountdown@@"$run".service \
    || systemctl start @idleCountdown@@"$run".timer
  keep-awake --take @domainName@ --drain --for 3m --why "@domainName@ idle" >/dev/null
else
  systemctl stop '@idleCountdown@@*.timer'
  if [ "$running" = true ]; then
    keep-awake --take @domainName@ --for 3m --why "@domainName@ in use" >/dev/null
  else
    keep-awake --release @domainName@
  fi
fi

shutsDownAt=$(systemctl list-timers --output=json @idleCountdown@@"$run".timer \
  | jq '.[0].next // empty | . / 1000000 | floor') || true
stopping=false
systemctl is-active -q @idleCountdown@@"$run".service && stopping=true

jq -cn --argjson locks "$locks" --argjson logins "$logins" \
  --argjson starting "$([ "$idle" = true ] && [ "$readyAt" -eq 0 ] && echo true || echo false)" \
  --argjson stopping "$stopping" --argjson updated "$(date +%s)" \
  --argjson shutsDownAt "${shutsDownAt:-null}" \
  --argjson idleAfter @idleAfter@ \
  '{locks:$locks,logins:$logins,starting:$starting,stopping:$stopping,updated:$updated,idleAfter:$idleAfter,shutsDownAt:$shutsDownAt}' \
  > @idleStatus@.tmp
mv @idleStatus@.tmp @idleStatus@

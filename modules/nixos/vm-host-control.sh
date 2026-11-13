state() { @virsh@ domstate @domainName@ 2>/dev/null || echo unknown; }
status_json() {
  local current idle='{}'
  current=$(state)
  if [ "$current" = running ] && [ -r @idleStatus@ ]; then
    idle=$(cat @idleStatus@)
  fi
  jq -cn --arg state "$current" --argjson idle "$idle" '{state:$state} + $idle'
}

case "${1:-}" in
  remote)
    case "${SSH_ORIGINAL_COMMAND:-}" in
      start)
        @resume@ >&2
        echo '{"ok":true}'
        ;;
      stop)
        if [ "$(state)" = paused ]; then
          @virsh@ resume @domainName@ >/dev/null
        fi
        @virsh@ shutdown @domainName@ >&2
        echo '{"ok":true}'
        ;;
      status) status_json ;;
      *)
        echo "usage: start | stop | status" >&2
        exit 2
        ;;
    esac
    ;;
  status-http)
    while IFS= read -r -t 2 line; do
      line=${line%$'\r'}
      [ -z "$line" ] && break
    done
    body=$(status_json)
    printf 'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
      "${#body}" "$body"
    ;;
  *)
    echo "usage: @domainName@-control remote | status-http" >&2
    exit 2
    ;;
esac

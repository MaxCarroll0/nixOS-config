remote="${BROWSER_SYNC_REMOTE:-pi}"
remoteRoot="${BROWSER_SYNC_ROOT:-/srv/browser-sync}"
profile="${BROWSER_SYNC_PROFILE:-$HOME/.config/chromium/Default}"
sessionDir="${BROWSER_SYNC_SESSIONS:-$HOME/Downloads/TabSessionManager}"
inbox="${BROWSER_SYNC_INBOX:-$HOME/.local/share/browser-sync}"
identity="${BROWSER_SYNC_IDENTITY:-$HOME/.ssh/id_ed25519}"
transport="${BROWSER_SYNC_SSH:-tailscale ssh}"
host="$(hostname)"

usage() {
  cat >&2 <<'EOF'
usage: browser-sync push [--what LIST]
       browser-sync pull --from HOST [--what LIST]
       browser-sync list

LIST is a comma-separated subset of: sessions,passwords,cookies,bookmarks,history
(default: sessions). Everything but sessions needs Chromium closed.
EOF
  exit 2
}

filesFor() {
  case "$1" in
    passwords) printf '%s\n' "Login Data" "Login Data For Account" ;;
    cookies) printf '%s\n' "Cookies" ;;
    bookmarks) printf '%s\n' "Bookmarks" ;;
    history) printf '%s\n' "History" ;;
    *)
      echo "browser-sync: unknown category '$1'" >&2
      exit 2
      ;;
  esac
}

chromiumRunning() {
  local lock pid
  lock="$(dirname "$profile")/SingletonLock"
  [ -L "$lock" ] || return 1
  pid="$(readlink "$lock")"
  pid="${pid##*-}"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

requireClosed() {
  chromiumRunning || return 0
  echo "browser-sync: Chromium is running; close it before touching profile data" >&2
  exit 1
}

recipientArgs() {
  local key
  for key in $recipients; do
    printf '%s\n' -R "$key"
  done
}

encryptTo() {
  local out="$1"
  mapfile -t args < <(recipientArgs)
  age "${args[@]}" -o "$out"
}

push() {
  local what="$1" tmp category
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  for category in ${what//,/ }; do
    if [ "$category" = sessions ]; then
      [ -d "$sessionDir" ] || {
        echo "browser-sync: no session directory at $sessionDir" >&2
        continue
      }
      tar -C "$(dirname "$sessionDir")" -cf - "$(basename "$sessionDir")" \
        | encryptTo "$tmp/sessions.age"
    else
      requireClosed
      mapfile -t names < <(filesFor "$category")
      local present=()
      local name
      for name in "${names[@]}"; do
        [ -f "$profile/$name" ] && present+=("$name")
      done
      [ ${#present[@]} -gt 0 ] || {
        echo "browser-sync: nothing to push for $category" >&2
        continue
      }
      tar -C "$profile" -cf - "${present[@]}" | encryptTo "$tmp/$category.age"
    fi
    echo "pushed $category"
  done

  date -Iseconds > "$tmp/pushed-at"
  $transport "$remote" "mkdir -p $remoteRoot/$host"
  rsync -a -e "$transport" "$tmp/" "$remote:$remoteRoot/$host/"
}

pull() {
  local from="$1" what="$2" tmp category stamp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  stamp="$(date +%Y%m%d-%H%M%S)"

  for category in ${what//,/ }; do
    rsync -a -e "$transport" "$remote:$remoteRoot/$from/$category.age" "$tmp/" 2>/dev/null || {
      echo "browser-sync: $from has no $category" >&2
      continue
    }

    if [ "$category" = sessions ]; then
      mkdir -p "$inbox/$from"
      age -d -i "$identity" < "$tmp/$category.age" | tar -C "$inbox/$from" -xf -
      echo "pulled $category from $from into $inbox/$from"
    else
      requireClosed
      mkdir -p "$inbox/backup/$stamp"
      mapfile -t names < <(filesFor "$category")
      local name
      for name in "${names[@]}"; do
        [ -f "$profile/$name" ] && cp -a "$profile/$name" "$inbox/backup/$stamp/"
      done
      age -d -i "$identity" < "$tmp/$category.age" | tar -C "$profile" -xf -
      echo "pulled $category from $from (previous copy in $inbox/backup/$stamp)"
    fi
  done
}

list() {
  $transport "$remote" "ls -lh $remoteRoot/*/ 2>/dev/null" || {
    echo "browser-sync: nothing stored on $remote yet" >&2
    exit 1
  }
}

action="${1:-}"
[ -n "$action" ] || usage
shift || true

what=sessions
from=""
while [ $# -gt 0 ]; do
  case "$1" in
    --what)
      what="${2:-}"
      shift 2
      ;;
    --from)
      from="${2:-}"
      shift 2
      ;;
    *) usage ;;
  esac
done

case "$action" in
  push) push "$what" ;;
  pull)
    [ -n "$from" ] || usage
    pull "$from" "$what"
    ;;
  list) list ;;
  *) usage ;;
esac

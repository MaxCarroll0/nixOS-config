usage() {
  printf '%s\n' \
    'keep-awake [--why REASON] [--shutdown] [--drain] [--] COMMAND [ARGS...]' \
    'keep-awake --for DURATION [--why REASON] [--shutdown] [--drain]' \
    'keep-awake --take NAME [--why REASON] [--for DURATION] [--shutdown] [--drain]' \
    'keep-awake --release NAME|all' \
    'keep-awake --list' \
    "" \
    'Holds a block inhibitor so the idle watcher leaves the host alone.' \
    '--drain blocks suspend without restarting the idle countdown.' \
    'DURATION accepts 90, 30m, 2h.'
}

seconds() {
  case "$1" in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *) echo "$1" ;;
  esac
}

# Tailscale SSH exports a usable user bus but no XDG_RUNTIME_DIR.
unit_scope() {
  if [ "$(id -u)" = 0 ]; then
    echo system
  elif [ -n "${XDG_RUNTIME_DIR:-}" ] || [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    echo user
  else
    echo system
  fi
}

scoped_systemctl() {
  if [ "$(unit_scope)" = user ]; then
    systemctl --user "$@"
  else
    systemctl "$@"
  fi
}

run_scoped() {
  if [ "$(unit_scope)" = user ]; then
    systemd-run --user "$@"
  else
    systemd-run "$@"
  fi
}

why="keep-awake"
what="sleep"
who="keep-awake"
duration=""
name=""
release=""
list=0

while [ $# -gt 0 ]; do
  case "$1" in
    --why) why="$2"; shift 2 ;;
    --for) duration="$2"; shift 2 ;;
    --take) name="$2"; shift 2 ;;
    --release) release="$2"; shift 2 ;;
    --list) list=1; shift ;;
    --shutdown) what="sleep:shutdown"; shift ;;
    --drain) who="keep-awake-drain"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ "$list" -eq 1 ]; then
  systemd-inhibit --list --no-pager
  exit 0
fi

if [ -n "$release" ]; then
  if [ "$release" = all ]; then
    scoped_systemctl stop 'keep-awake-*' 2>/dev/null || true
  else
    scoped_systemctl stop "keep-awake-$release.service" 2>/dev/null || true
  fi
  exit 0
fi

if [ -n "$name" ]; then
  unit="keep-awake-$name"
  secs=$(seconds "${duration:-24h}")
  if scoped_systemctl is-active --quiet "$unit.service" 2>/dev/null; then
    if [ -z "$duration" ]; then
      exit 0
    fi
    scoped_systemctl stop "$unit.service" 2>/dev/null || true
  fi
  run_scoped --quiet --collect --unit "$unit" \
    --property=RuntimeMaxSec="$secs" \
    --description="keep-awake: $why" \
    -- systemd-inhibit --mode=block --what="$what" --who="$who" --why="$why" \
      -- @sleep@ "$secs"
  echo "$unit"
  exit 0
fi

if [ -n "$duration" ]; then
  secs=$(seconds "$duration")
  unit="keep-awake-$(date +%s)-$$"
  run_scoped --quiet --collect --unit "$unit" \
    --property=RuntimeMaxSec="$secs" \
    --description="keep-awake: $why" \
    -- systemd-inhibit --mode=block --what="$what" --who="$who" --why="$why" \
      -- @sleep@ "$secs"
  echo "$unit"
  exit 0
fi

if [ $# -eq 0 ]; then
  usage >&2
  exit 2
fi

exec systemd-inhibit --mode=block --what="$what" --who="$who" --why="$why" -- "$@"

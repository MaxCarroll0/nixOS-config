builder="$DEV_BUILD_BUILDER"
builderAddress="$DEV_BUILD_BUILDER_ADDRESS"
offloadable="$DEV_BUILD_CAN_OFFLOAD"
threshold="${DEV_BUILD_THRESHOLD:-$DEV_BUILD_DEFAULT_THRESHOLD}"
remoteRoot="$DEV_BUILD_REMOTE_ROOT"
excludes="$DEV_BUILD_EXCLUDES"
state="${XDG_STATE_HOME:-$HOME/.local/state}/dev-build"
self=$(uname -n)

usage() {
  cat <<EOF
usage: dev-build [--local|--remote] [--root DIR] CMD...   run the project's build here or on $builder
       dev-build run [-p PORT]... CMD...                  run CMD on $builder in the project, interactive
       dev-build ls [PATH]                                files the builds wrote on $builder, with sizes
       dev-build get PATH...                              copy those files from $builder into the project
       dev-build cat PATH                                 print a file from $builder
       dev-build status                                   timings, where each command last ran, builder state
       dev-build forget                                   drop this project's timings

A single argument is a shell command line; several arguments are one command's words.
The first run of a command is measured here; a command that took ${threshold}s or more goes
to $builder afterwards. Nothing is copied back: ls, get, cat and run reach the builder's
copy on demand. The command sees DEV_BUILD_HOST set to the machine it runs on.
Everything a wrapped command writes is recorded and reclaimable; keep results by
committing them or copying them out with get.
EOF
}

sshOpts=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

where="${DEV_BUILD_WHERE:-auto}"
root=""
action=build
ports=()

case "${1:-}" in
  run|ls|get|cat|status|forget) action=$1; shift ;;
  --status) action=status; shift ;;
  --forget) action=forget; shift ;;
  -h|--help) usage; exit 0 ;;
esac

while true; do
  case "${1:-}" in
    --local) where=local; shift ;;
    --remote) where=remote; shift ;;
    --root) root="${2:?--root needs a directory}"; shift 2 ;;
    -p) ports+=("${2:?-p needs a port}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "dev-build: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ -z "$root" ]; then
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
project=$(basename "$root")
record="$state/$project"
target="$remoteRoot/$project"
profile="$target/.dev-build-profile"
mkdir -p "$record"
printf '%s\n' "$root" > "$record/root"

remoteShell() {
  ssh "${sshOpts[@]}" "max@$builderAddress" "$@"
}

needBuilder() {
  if [ "$offloadable" != 1 ]; then
    echo "dev-build: no builder configured for this host" >&2
    exit 2
  fi
}

builderState() {
  [ "$offloadable" = 1 ] || return 0
  local remote
  remote=$(ssh "${sshOpts[@]}" -o ConnectTimeout=3 "max@$builderAddress" \
    "stat -c %Y '$target/.dev-build-last-used' 2>/dev/null || echo absent" 2>/dev/null) || remote=unreachable
  case "$remote" in
    absent) echo "$builder: no copy of $project; the next remote run syncs everything" ;;
    unreachable) echo "$builder: unreachable, not woken" ;;
    *) echo "$builder: holds $project, last used $(date -d "@$remote" '+%F %R')" ;;
  esac
}

recordArtefacts() {
  local dir=$1 stamp=$2 manifest=$3 entry
  {
    [ -f "$manifest" ] && cat "$manifest"
    if git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
      git -C "$dir" status --porcelain --ignored=matching --untracked-files=all -z \
        | tr '\0' '\n' | sed -n 's/^!! //p' \
        | while IFS= read -r entry; do
            [ -n "$(find "$dir/$entry" -newer "$stamp" -print -quit 2>/dev/null)" ] && printf '%s\n' "$entry"
          done || true
    else
      find "$dir" -newer "$stamp" -type f -printf '%P\n'
    fi
  } | grep -v '^\.dev-build-' | sort -u > "$manifest.tmp" || true
  mv "$manifest.tmp" "$manifest"
}

enterCommand() {
  local dir=$1 command=$2 profileLink=$3
  if [ -e "$dir/flake.nix" ]; then
    printf 'nix develop %s -c bash -c %q\n' "${profileLink:+--profile $profileLink}" "$command"
  elif [ -e "$dir/shell.nix" ] || [ -e "$dir/default.nix" ]; then
    printf 'nix-shell %s --run %q\n' "${profileLink:+--add-root $profileLink --indirect}" "$command"
  else
    printf 'bash -c %q\n' "$command"
  fi
}

case "$action" in
  status)
    if [ -z "$(find "$record" -name '*.timing' -print -quit)" ]; then
      echo "no timings recorded for $project"
    else
      printf '%7s %-12s %6s  %s\n' seconds 'last ran on' sync command
      for f in "$record"/*.timing; do
        mapfile -t line < "$f"
        if [ "${line[0]}" -ge "$threshold" ] && [ "$offloadable" = 1 ]; then verdict=$builder; else verdict=here; fi
        printf '%7s %-12s %6s  %s   (next: %s)\n' "${line[0]}" "${line[2]:-here}" "${line[3]:-0}s" "${line[1]}" "$verdict"
      done
    fi
    if [ -s "$record/artefacts" ]; then
      echo "recorded here: $(wc -l < "$record/artefacts") artefact paths (project-scratch-clean reclaims them)"
    fi
    builderState
    exit 0 ;;
  forget)
    rm -f "$record"/*.timing
    echo "dropped the timings for $project"
    exit 0 ;;
  ls)
    needBuilder
    prefix="${1:-}"
    remoteShell "cd '$target' 2>/dev/null || exit 3; [ -s .dev-build-artefacts ] || exit 4; awk -v p='${prefix//\'/}' 'p == \"\" || index(\$0, p) == 1' .dev-build-artefacts | xargs -r -d '\n' du -sh 2>/dev/null" || {
      case $? in
        3) echo "$builder has no copy of $project" >&2; exit 1 ;;
        4) echo "no build has recorded artefacts on $builder for $project" >&2; exit 1 ;;
        *) echo "dev-build: $builder is unreachable" >&2; exit 1 ;;
      esac
    }
    exit 0 ;;
  get)
    needBuilder
    [ $# -gt 0 ] || { echo "usage: dev-build get PATH..." >&2; exit 2; }
    for path in "$@"; do
      rsync -a --relative --mkpath -e "ssh ${sshOpts[*]}" "max@$builderAddress:$target/./$path" "$root/"
      echo "$root/$path"
    done
    exit 0 ;;
  cat)
    needBuilder
    [ $# -eq 1 ] || { echo "usage: dev-build cat PATH" >&2; exit 2; }
    remoteShell "cat '$target/${1//\'/}'"
    exit 0 ;;
esac

if [ $# -eq 0 ]; then
  usage >&2
  exit 2
fi

if [ $# -eq 1 ]; then
  command=$1
else
  printf -v command '%q ' "$@"
fi

reach() {
  ssh "${sshOpts[@]}" "max@$builderAddress" true 2>/dev/null
}

wakeBuilder() {
  reach && return 0
  if command -v wake-peer >/dev/null 2>&1; then
    echo "dev-build: waking $builder" >&2
    wake-peer "$builder" >&2 || true
  fi
  reach
}

if [ "$action" = run ]; then
  needBuilder
  wakeBuilder || { echo "dev-build: $builder is unreachable" >&2; exit 1; }
  ttyOpts=()
  [ -t 0 ] && ttyOpts=(-t)
  forwards=()
  for port in "${ports[@]}"; do
    forwards+=(-L "$port:127.0.0.1:$port")
    echo "dev-build: localhost:$port here reaches $builder:$port" >&2
  done
  echo "dev-build: running on $builder in $target" >&2
  remoteScript=$(printf 'cd %q 2>/dev/null || { echo "dev-build: %s has no copy of %s; build first" >&2; exit 3; }\ntouch .dev-build-last-used\nexport DEV_BUILD_HOST=%q\n%s' \
    "$target" "$builder" "$project" "$builder" "$(enterCommand "$root" "$command" "$profile")")
  exec ssh "${sshOpts[@]}" "${ttyOpts[@]}" "${forwards[@]}" "max@$builderAddress" "bash -c $(printf %q "$remoteScript")"
fi

timing="$record/$(printf '%s' "$command" | sha1sum | cut -d' ' -f1).timing"

if [ "$where" = auto ]; then
  where=local
  if [ "$offloadable" = 1 ] && [ -r "$timing" ] && [ "$(sed -n 1p "$timing")" -ge "$threshold" ]; then
    where=remote
  fi
fi

if [ "$where" = remote ] && [ "$offloadable" = 0 ]; then
  echo "dev-build: no builder to defer to; building here" >&2
  where=local
fi

if [ "$where" = remote ] && ! wakeBuilder; then
  echo "dev-build: $builder is unreachable; building here" >&2
  where=local
fi

started=$SECONDS
status=0

if [ "$where" = local ]; then
  echo "dev-build: running here in $root" >&2
  stamp=$(mktemp)
  trap 'rm -f "$stamp"' EXIT
  (cd "$root" && DEV_BUILD_HOST=$self exec bash -c "$(enterCommand "$root" "$command" "")") || status=$?
  recordArtefacts "$root" "$stamp" "$record/artefacts"
  elapsed=$((SECONDS - started))
  printf '%s\n%s\n%s\n%s\n' "$elapsed" "$command" "$self" 0 > "$timing"
  if [ "$elapsed" -ge "$threshold" ] && [ "$offloadable" = 1 ]; then
    echo "dev-build: that took ${elapsed}s; the next one goes to $builder" >&2
  fi
  exit "$status"
fi

echo "dev-build: running on $builder in $target" >&2
rsync -a --compress --delete --mkpath \
  --exclude-from="$excludes" \
  -e "ssh ${sshOpts[*]}" \
  "$root/" "max@$builderAddress:$target/"
synced=$((SECONDS - started))

remoteScript=$(
  printf 'set -uo pipefail\n'
  printf 'export NIX_OBSERVER_PLAIN=1 DEV_BUILD_HOST=%q\n' "$builder"
  printf 'cd %q\n' "$target"
  printf 'touch .dev-build-last-used\n'
  printf 'stamp=$(mktemp)\n'
  printf '%s\n' "$(enterCommand "$root" "$command" "$profile")"
  printf 'status=$?\n'
  declare -f recordArtefacts
  printf 'recordArtefacts %q "$stamp" %q\n' "$target" "$target/.dev-build-artefacts"
  printf 'rm -f "$stamp"\n'
  printf 'exit $status\n'
)
ttyOpts=()
[ -t 0 ] && ttyOpts=(-t)
ssh "${sshOpts[@]}" "${ttyOpts[@]}" "max@$builderAddress" "bash -c $(printf %q "$remoteScript")" 2>&1 \
  | sed -u "s#$target#$root#g" || status=$?

elapsed=$((SECONDS - started))
printf '%s\n%s\n%s\n%s\n' "$elapsed" "$command" "$builder" "$synced" > "$timing"
echo "dev-build: $project on $builder took ${elapsed}s (sync ${synced}s); outputs stay there: dev-build ls, get, run" >&2
exit "$status"

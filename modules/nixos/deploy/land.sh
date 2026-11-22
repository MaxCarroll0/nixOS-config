flake="$REBUILD_FLAKE"
g() { git -C "$flake" "$@"; }

usage() {
  cat <<'EOF'
usage: land -m SUBJECT [PATH ...]
       land --status [SESSION]

Commits PATHs (default: every path this Claude session's snapshots changed) as one commit on
origin/main, pushes it, and moves this clone's main to it. Each path must still hold what its
latest snapshot deployed. Then redeploy each listed host with a plain rebuild, which builds HEAD.

--status prints one line per open snapshot of SESSION (default: this session):
  unlanded NODE REV PATHS   the snapshot's paths are not on origin/main
  redeploy NODE REV PATHS   landed, but NODE does not run them from main
Snapshots that are landed and deployed from main are closed (their ref is deleted).
EOF
}

session="${CLAUDE_CODE_SESSION_ID:-}"

snapshotPaths() { g diff --name-only "$1^" "$1"; }

sessionRefs() {
  g for-each-ref --sort=committerdate --format='%(refname) %(objectname)' "refs/sessions/$1/"
}

status() {
  local ref rev node deployed
  local -a paths
  g fetch -q origin main '+refs/deploys/*:refs/remotes/deploys/*' 2>/dev/null || true
  while read -r ref rev; do
    [ -n "$ref" ] || continue
    node=${ref##*/}
    mapfile -t paths < <(snapshotPaths "$rev")
    deployed=$(g rev-parse -q --verify "refs/remotes/deploys/$node" 2>/dev/null \
      || g rev-parse -q --verify "refs/deploys/$node" 2>/dev/null || true)
    if ! g diff --quiet "$rev" origin/main -- "${paths[@]}"; then
      echo "unlanded $node ${rev:0:7} ${paths[*]}"
    elif [ "$deployed" = "$rev" ] || { [ -n "$deployed" ] && ! g diff --quiet "$deployed" origin/main -- "${paths[@]}"; }; then
      echo "redeploy $node ${rev:0:7} ${paths[*]}"
    else
      g update-ref -d "$ref"
    fi
  done < <(sessionRefs "$1")
}

blobOf() {
  if [ -e "$flake/$1" ]; then
    (cd "$flake" && git hash-object -- "$1")
  fi
}

commitOnto() {
  local parent=$1 index patch
  index=$(mktemp)
  patch=$(mktemp)
  GIT_INDEX_FILE=$index g read-tree HEAD
  GIT_INDEX_FILE=$index g add -A -- "${paths[@]}"
  GIT_INDEX_FILE=$index g diff --cached --binary HEAD > "$patch"
  GIT_INDEX_FILE=$index g read-tree "$parent"
  if [ -s "$patch" ] && ! GIT_INDEX_FILE=$index g apply --cached --3way "$patch" >&2; then
    rm -f "$index" "$patch"
    echo "error: ${paths[*]} do not apply onto ${parent:0:7}; origin changed them too" >&2
    return 1
  fi
  g commit-tree "$(GIT_INDEX_FILE=$index g write-tree)" -p "$parent" -m "$subject"
  rm -f "$index" "$patch"
}

subject=""
paths=()
while [ $# -gt 0 ]; do
  case "$1" in
    --status) status "${2:-$session}"; exit 0 ;;
    -m) subject="${2:?-m needs a subject}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; paths+=("$@"); break ;;
    -*) usage >&2; exit 2 ;;
    *) paths+=("$1"); shift ;;
  esac
done
[ -n "$subject" ] || { usage >&2; exit 2; }

branch=$(g symbolic-ref --short -q HEAD || echo detached)
if [ "$branch" != main ]; then
  echo "error: land commits on main in the main clone; $flake is on $branch" >&2
  exit 2
fi

declare -A latest=()
nodes=()
if [ -n "$session" ]; then
  while read -r ref rev; do
    [ -n "$ref" ] || continue
    nodes+=("${ref##*/}")
    while read -r p; do latest[$p]=$rev; done < <(snapshotPaths "$rev")
  done < <(sessionRefs "$session")
fi
if [ "${#paths[@]}" -eq 0 ]; then
  paths=("${!latest[@]}")
  [ "${#paths[@]}" -gt 0 ] || { echo "error: this session deployed no snapshot; name the paths to land" >&2; exit 2; }
fi

for p in "${paths[@]}"; do
  if [ -z "${latest[$p]:-}" ]; then
    echo "warning: no snapshot of this session deployed $p" >&2
  elif [ "$(blobOf "$p")" != "$(g rev-parse -q --verify "${latest[$p]}:$p" 2>/dev/null || true)" ]; then
    echo "error: $p changed since ${latest[$p]:0:7} deployed it; redeploy with rebuild --only first" >&2
    exit 1
  fi
done

for attempt in 1 2 3; do
  g fetch -q origin main
  unpushed=$(g cherry origin/main HEAD | grep '^+' || true)
  if [ -n "$unpushed" ]; then
    echo "error: main has commits origin lacks; push or drop them first:" >&2
    g log --oneline --no-walk "$(cut -c3- <<<"$unpushed")" >&2
    exit 1
  fi

  if g merge-base --is-ancestor HEAD origin/main; then
    g merge -q --ff-only origin/main 2>/dev/null && moved=1 || moved=0
  else
    g reset -q --keep origin/main 2>/dev/null && moved=1 || moved=0
  fi

  commit=$(commitOnto origin/main) || exit 1
  if ! g push -q origin "$commit:refs/heads/main"; then
    echo "origin moved during attempt $attempt; landing again on it" >&2
    continue
  fi

  if [ "$moved" = 1 ]; then
    g update-ref -m "land: $subject" refs/heads/main "$commit"
    g reset -q -- "${paths[@]}"
    echo "landed $(g log -1 --format='%h %s' "$commit"); main is at it"
  else
    echo "landed $(g log -1 --format='%h %s' "$commit") on origin; this clone stays on ${branch} $(g rev-parse --short HEAD)"
    echo "  because origin changed files that have uncommitted work here; pull once that work lands"
  fi
  mapfile -t nodes < <(printf '%s\n' "${nodes[@]}" | sort -u | grep -v '^$' || true)
  if [ "${#nodes[@]}" -gt 0 ]; then
    echo "now put each host on HEAD (no --only): ${nodes[*]}"
  fi
  exit 0
done
echo "error: origin kept moving; land again" >&2
exit 1

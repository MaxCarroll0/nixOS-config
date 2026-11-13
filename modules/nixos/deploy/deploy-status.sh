flake="$REBUILD_FLAKE"
self="$REBUILD_HOST"
read -ra nodes <<<"$REBUILD_NODES"

usage() {
  cat <<'EOF'
usage: deploy-status [--no-fetch] [NODE ...]

One line per host: the revision it runs, how it relates to main, and any uncommitted
snapshot it was deployed from. Sleeping hosts are reported, never woken.
EOF
}

fetch=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) fetch=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] && nodes=("$@")

if [ "$fetch" = 1 ]; then
  timeout 15 git -C "$flake" fetch -q origin 'main' '+refs/deploys/*:refs/remotes/deploys/*' 2>/dev/null || true
fi
main=$(git -C "$flake" rev-parse -q --verify origin/main 2>/dev/null || git -C "$flake" rev-parse main)

online() {
  [ "$1" = "$self" ] && return 0
  tailscale status --json 2>/dev/null \
    | jq -e --arg h "$1" '.Peer[] | select(.HostName == $h) | .Online' >/dev/null 2>&1
}

runningRevision() {
  if [ "$1" = "$self" ]; then
    nixos-version --configuration-revision 2>/dev/null
  else
    timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 "$1" nixos-version --configuration-revision 2>/dev/null
  fi
}

describe() {
  local rev=$1 subject
  if ! git -C "$flake" cat-file -e "$rev^{commit}" 2>/dev/null; then
    echo "unknown commit ${rev:0:7}: not in this clone"
    return
  fi
  subject=$(git -C "$flake" log -1 --format=%s "$rev")
  if git -C "$flake" merge-base --is-ancestor "$rev" "$main"; then
    local behind
    behind=$(git -C "$flake" rev-list --count "$rev..$main")
    if [ "$behind" = 0 ]; then echo "main (${rev:0:7})"; else echo "main~$behind (${rev:0:7})"; fi
    return
  fi
  case "$subject" in
    snapshot:*)
      local files
      files=$(git -C "$flake" diff --name-only "$main...$rev" | paste -sd, | cut -c1-80)
      echo "SNAPSHOT ${rev:0:7} ${subject#snapshot: }: differs from main in $files" ;;
    *)
      echo "UNLANDED ${rev:0:7} \"$subject\": not an ancestor of main" ;;
  esac
}

printf '%-12s %s\n' host running
for node in "${nodes[@]}"; do
  if ! online "$node"; then
    printf '%-12s %s\n' "$node" "offline or asleep (not woken)"
    continue
  fi
  rev=$(runningRevision "$node" || true)
  case "$rev" in
    "") printf '%-12s %s\n' "$node" "unreachable" ;;
    *-dirty) printf '%-12s %s\n' "$node" "DIRTY build of $(describe "${rev%-dirty}"); diff unknown (deployed before snapshots)" ;;
    *) printf '%-12s %s\n' "$node" "$(describe "$rev")" ;;
  esac
done

echo
dirty=$(git -C "$flake" status --porcelain --untracked-files=normal -- . ':!CLAUDE.md' ':!AGENTS.md' | wc -l)
ahead=$(git -C "$flake" rev-list --count "$main..HEAD" 2>/dev/null || echo 0)
behind=$(git -C "$flake" rev-list --count "HEAD..$main" 2>/dev/null || echo 0)
echo "this clone: HEAD $(git -C "$flake" rev-parse --short HEAD), $ahead ahead / $behind behind origin/main, $dirty uncommitted paths"
flakeSyncState=/var/lib/flake-sync
if [ -s "$flakeSyncState/lag" ]; then echo "flake-sync: $(cat "$flakeSyncState/lag")"; fi
held=$(jq -r 'keys | join(", ")' "$flakeSyncState/held.json" 2>/dev/null || true)
if [ -n "$held" ]; then echo "held back on $self: $held"; fi
for ref in $(git -C "$flake" for-each-ref --format='%(refname:short)' refs/deploys/ 2>/dev/null); do
  r=$(git -C "$flake" rev-parse "$ref")
  git -C "$flake" merge-base --is-ancestor "$r" "$main" && continue
  echo "  $ref: ${r:0:7} $(git -C "$flake" log -1 --format=%s "$r") [$(git -C "$flake" log -1 --format=%cr "$r")]"
done

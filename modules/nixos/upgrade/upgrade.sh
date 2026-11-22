flake=$UPGRADE_FLAKE
host=$UPGRADE_HOST
state=${STATE_DIRECTORY:-/var/lib/nixos-upgrade}
work=$(mktemp -d "$state/work.XXXXXX")
chown max "$work"
trap 'release_deploy; rm -rf "$work"' EXIT

repo_git() { runuser -u max -- git -C "$flake" "$@"; }
index_git() { runuser -u max -- env GIT_INDEX_FILE="$work/index" git -C "$flake" "$@"; }
asmax() { runuser -u max -- env HOME=/home/max "$@"; }

repo_git fetch -q origin '+refs/heads/main:refs/remotes/origin/main' '+refs/deploys/*:refs/remotes/deploys/*' \
  || echo "warning: cannot reach origin; upgrading with the lock this clone last fetched" >&2

claimed=0
for _ in $(seq 1 12); do
  if claim_deploy "$host" "$(repo_git rev-parse origin/main)" "nixos-upgrade on $host"; then
    claimed=1
    break
  fi
  sleep 300
done
if [ "$claimed" = 0 ]; then
  echo "<3>$host stayed claimed by another deploy for an hour"
  exit 1
fi

running=$(nixos-version --configuration-revision 2>/dev/null || true)
running=${running%-dirty}
if [ -n "$running" ] && repo_git cat-file -e "$running^{commit}" 2>/dev/null; then
  base=$running
else
  echo "<4>the running revision ${running:-(none)} is not in this clone; upgrading origin/main instead"
  base=$(repo_git rev-parse origin/main)
  running=""
fi
src=$(upgrade_base "$base")
srcRef="git+file://$flake?rev=$src"
target="$srcRef#nixosConfigurations.$host.config.system.build.toplevel"
echo "upgrading ${src:0:7} ($(repo_git log -1 --format=%s "$src")) with origin's inputs"

repo_git show "$base:flake.lock" > "$work/running.lock"
repo_git show origin/main:flake.lock > "$work/origin.lock"

srcPath=$(asmax nix eval --impure --raw --expr "(builtins.fetchGit { url = \"$flake\"; rev = \"$src\"; allRefs = true; }).outPath")
pins=()
if [ -f "$srcPath/hosts/$host/pins.nix" ]; then
  out=$(asmax nix eval --impure --raw --expr "builtins.concatStringsSep \"\\n\" (import $srcPath/lib/pins.nix { root = $srcPath; host = \"$host\"; }).argv")
  [ -n "$out" ] && mapfile -t pins <<<"$out"
fi
pinned=()
for ((i = 1; i < ${#pins[@]}; i += 3)); do pinned+=("${pins[$i]}"); done

mapfile -t changed < <(
  jq -rn --slurpfile old "$work/running.lock" --slurpfile new "$work/origin.lock" '
    def locked($k; $n): $k.nodes.root.inputs[$n] as $i
      | if ($i | type) == "string" then $k.nodes[$i].locked else null end;
    $old[0].nodes.root.inputs | keys[] | select(locked($old[0]; .) != locked($new[0]; .))
  ' | grep -vxF -f <(printf '%s\n' "${pinned[@]}" "") || true
)

if [ "${#changed[@]}" -eq 0 ] && [ -n "$running" ]; then
  echo "${base:0:7} already has every input origin has"
  exit 0
fi

holdRef() {
  jq -r --arg n "$1" '
    .nodes[.nodes.root.inputs[$n]].locked
    | if .type == "github" then "github:\(.owner)/\(.repo)/\(.rev)"
      elif .type == "gitlab" then "gitlab:\(.owner)/\(.repo)/\(.rev)"
      elif .type == "git" then "git+\(.url)?rev=\(.rev)\(if .ref then "&ref=\(.ref)" else "" end)"
      elif .type == "tarball" or .type == "file" then .url
      elif .type == "path" then "path:\(.path)"
      else empty end
  ' "$work/running.lock"
}

mklock() {
  local args=() name ref
  for name in "$@"; do
    ref=$(holdRef "$name")
    [ -n "$ref" ] || return 1
    args+=(--override-input "$name" "$ref")
  done
  asmax nix flake lock "$srcRef" --reference-lock-file "$work/origin.lock" \
    --output-lock-file "$work/try.lock" "${args[@]}"
}

uncached_kernels() {
  asmax nix build --dry-run --no-write-lock-file --reference-lock-file "$work/try.lock" "${pins[@]}" "$target" 2>&1 \
    | grep -oE '/nix/store/[a-z0-9]{32}-linux(_[^/" ]*)?-[0-9][^/" ]*\.drv' \
    | grep -vE -- '-modules(-shrunk)?\.drv$'
}

attempt() {
  mklock "$@" || return 1
  local kernels
  if kernels=$(uncached_kernels); then
    echo "<4>not in any cache, so not compiled here: $kernels"
    return 1
  fi
  asmax nix build --no-write-lock-file --reference-lock-file "$work/try.lock" -o "$work/result" "${pins[@]}" "$target"
}

held=()
if ! attempt; then
  held=("${changed[@]}")
  if ! attempt "${held[@]}"; then
    echo "<3>${src:0:7} does not build for $host even with the inputs it runs"
    exit 1
  fi
  for name in "${changed[@]}"; do
    trial=()
    for other in "${held[@]}"; do [ "$other" = "$name" ] || trial+=("$other"); done
    attempt "${trial[@]}" && held=("${trial[@]}")
  done
  attempt "${held[@]}"
  echo "<4>held back on $host: ${held[*]}"
fi
printf '%s\n' "${held[@]}" > "$state/held"

blob=$(runuser -u max -- git -C "$flake" hash-object -w --stdin < "$work/try.lock")
index_git read-tree "$src"
index_git update-index --cacheinfo "100644,$blob,flake.lock"
tree=$(index_git write-tree)
if [ "$tree" = "$(repo_git rev-parse "$src^{tree}")" ]; then
  new=$src
else
  bumped=$(jq -rn --slurpfile old "$work/running.lock" --slurpfile new "$work/try.lock" '
    def locked($k; $n): $k.nodes.root.inputs[$n] as $i
      | if ($i | type) == "string" then $k.nodes[$i].locked else null end;
    [$new[0].nodes.root.inputs | keys[] | select(locked($old[0]; .) != locked($new[0]; .))] | join(" ")')
  new=$(repo_git commit-tree "$tree" -p "$src" -m "upgrade: $host ${bumped:-inputs}")
fi
if [ "$new" = "$running" ]; then
  echo "$host already runs ${new:0:7}"
  exit 0
fi

repo_git update-ref "refs/deploys/$host.pending" "$new"
asmax nix build -o "$work/result" "${pins[@]}" \
  "git+file://$flake?ref=refs/deploys/$host.pending&rev=$new#nixosConfigurations.$host.config.system.build.toplevel"
system=$(readlink -f "$work/result")

action=switch
if [ "${UPGRADE_SESSION_SAFE:-0}" = 1 ]; then
  for part in systemd etc/systemd/user; do
    if [ "$(readlink -f "/run/current-system/$part")" != "$(readlink -f "$system/$part")" ]; then
      echo "the new system changes $part, which restarts the graphical session; staging it for the next lock, sleep or logout"
      action=boot
      break
    fi
  done
fi

if [ "${1:-}" = --dry-run ]; then
  repo_git update-ref -d "refs/deploys/$host.pending"
  echo "dry run: would $action $system as ${new:0:7} ($(repo_git log -1 --format=%s "$new"))"
  exit 0
fi

if [ "$action" = boot ]; then echo "$system" > "$state/staged"; else rm -f "$state/staged"; fi
nix-env -p /nix/var/nix/profiles/system --set "$system"
"$system/bin/switch-to-configuration" "$action"

repo_git update-ref "refs/deploys/$host" "$new"
repo_git push -q --force origin "$new:refs/deploys/$host" \
  || echo "<4>could not push refs/deploys/$host; other machines cannot see this upgrade"
echo "$action ${new:0:7} ($(repo_git log -1 --format=%s "$new"))"

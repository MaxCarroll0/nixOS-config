host="$REBUILD_HOST"
flake="$REBUILD_FLAKE"
stateDir="${XDG_STATE_HOME:-$HOME/.local/state}/rebuild"
opts=()
rebuildStarted=$SECONDS
rebuildKind=rebuild
rebuildTarget="$host"
rebuildAction=switch

logRebuildCompletion() {
  rebuildExit=$?
  trap - EXIT
  release_deploy
  if [ "$rebuildExit" -eq 0 ]; then
    rebuildStatus=success
  else
    rebuildStatus=failed
  fi
  logger -t nix-observer-summary -- "{\"event\":\"nix_rebuild\",\"status\":\"$rebuildStatus\",\"exit_code\":$rebuildExit,\"duration_seconds\":$((SECONDS - rebuildStarted)),\"host\":\"$host\",\"project\":\"nix\",\"kind\":\"$rebuildKind\",\"target\":\"$rebuildTarget\",\"action\":\"$rebuildAction\",\"alert_eligible\":true}"
  echo "EXIT=$rebuildExit"
  exit "$rebuildExit"
}
trap logRebuildCompletion EXIT

usage() {
  cat <<'EOF'
usage: rebuild [--local|--mixed] [--host NODE] [--profile system|home]
               [--note TEXT] [--supersede] [--log PATH] [--only PATH]... [--base REV]
               [ACTION] [nixos-rebuild args]

ACTION defaults to switch. Local: switch boot test dry-activate build dry-build repl home.
Remote (--host): switch boot test dry-activate.

Without --only, rebuild builds HEAD exactly, or origin/main when this clone is behind it, or
--base REV; it refuses a commit that lacks anything landed on origin/main. Uncommitted work is
listed and left out.
With --only, it builds the revision the target runs (or --base REV) plus the uncommitted
changes under each PATH, as a snapshot commit on refs/deploys/NODE pushed to origin, so the
target's configuration revision is always a real commit. --note labels that snapshot.
--supersede deploys over a revision deployed from another machine.
EOF
}

target=""
profile=""
note=""
supersede=0
logPath=""
onlyPaths=()
baseArg=""
while true; do
  case "${1:-}" in
    --local) opts+=(--option builders ""); shift ;;
    --mixed) opts+=(--option builders "@/etc/nix/machines"); shift ;;
    --host) target="${2:?--host needs a node name}"; shift 2 ;;
    --profile) profile="${2:?--profile needs system or home}"; shift 2 ;;
    --note) note="${2:?--note needs text}"; shift 2 ;;
    --supersede) supersede=1; shift ;;
    --only) onlyPaths+=("${2:?--only needs a path}"); shift 2 ;;
    --base) baseArg="${2:?--base needs a revision}"; shift 2 ;;
    --log) logPath="${2:?--log needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done

action="${1:-switch}"
[ $# -gt 0 ] && shift

export NIX_OBSERVER_KIND=rebuild
export NIX_OBSERVER_TARGET="${target:-$host}"
rebuildTarget="$NIX_OBSERVER_TARGET"
rebuildAction="$action"

mkdir -p "$stateDir"
if [ ! -t 1 ]; then
  export NIX_OBSERVER_PLAIN="${NIX_OBSERVER_PLAIN:-1}"
  [ -n "$logPath" ] || logPath="$stateDir/$rebuildTarget-$(date +%s).log"
fi
if [ -n "$logPath" ]; then
  echo "log: $logPath"
  exec > >(tee -a "$logPath") 2>&1
fi

activating() {
  case "$action" in switch|boot|test) return 0 ;; *) return 1 ;; esac
}

runningRevision() {
  local running
  if [ "$profile" = home ] || [ "$action" = home ]; then
    return
  fi
  if [ -z "$target" ]; then
    running=$(nixos-version --configuration-revision 2>/dev/null || true)
  else
    git -C "$flake" fetch -q origin "+refs/deploys/$rebuildTarget:refs/remotes/deploys/$rebuildTarget" 2>/dev/null || true
    running=$(git -C "$flake" rev-parse -q --verify "refs/remotes/deploys/$rebuildTarget" 2>/dev/null \
      || git -C "$flake" rev-parse -q --verify "refs/deploys/$rebuildTarget" 2>/dev/null || true)
  fi
  running=${running%-dirty}
  [ -n "$running" ] && git -C "$flake" cat-file -e "$running^{commit}" 2>/dev/null && echo "$running"
}

snapshotRevision() {
  local index tree subject
  index=$(mktemp)
  trap 'rm -f "$index"' RETURN
  if ! overlayOnto "$base" "$index" "${onlyPaths[@]}"; then
    echo "error: the changes under ${onlyPaths[*]} do not apply onto ${base:0:7}; pass --base HEAD to build on HEAD instead" >&2
    return 1
  fi
  tree=$(GIT_INDEX_FILE=$index git -C "$flake" write-tree)
  if [ "$tree" = "$(git -C "$flake" rev-parse "$base^{tree}")" ]; then
    echo "$base"
    return
  fi
  subject="snapshot: $rebuildTarget $action${note:+ ($note)}"
  GIT_INDEX_FILE=$index git -C "$flake" commit-tree "$tree" -p "$base" -m "$subject" \
    -m "$(GIT_INDEX_FILE=$index git -C "$flake" diff --cached --stat "$base")"
}

dirtyPaths() {
  git -C "$flake" status --porcelain=v1 -uall --no-renames "$@" | cut -c4-
}

headRev=$(git -C "$flake" rev-parse HEAD)
final=$headRev
if [ "${#onlyPaths[@]}" -eq 0 ]; then
  timeout 15 git -C "$flake" fetch -q origin main 2>/dev/null || true
  mainRev=$(git -C "$flake" rev-parse -q --verify origin/main 2>/dev/null || true)
  if [ -n "$baseArg" ]; then
    final=$(git -C "$flake" rev-parse --verify "$baseArg^{commit}") || exit 2
  elif [ -n "$mainRev" ] && [ "$mainRev" != "$headRev" ] && git -C "$flake" merge-base --is-ancestor "$headRev" "$mainRev"; then
    echo "note: HEAD ${headRev:0:7} is behind origin/main, which has landed commits this clone has not pulled; building origin/main"
    final=$mainRev
  fi
  if [ -n "$mainRev" ] && ! git -C "$flake" merge-base --is-ancestor "$mainRev" "$final"; then
    echo "error: ${final:0:7} lacks commits landed on origin/main ${mainRev:0:7}; deploying it would drop them" >&2
    echo "  land or rebase local commits first, or deploy origin/main with --base origin/main" >&2
    exit 2
  fi
fi
running=$(runningRevision || true)
carried=()
if [ -n "$running" ] && ! git -C "$flake" merge-base --is-ancestor "$running" "$final"; then
  mapfile -t carried < <(git -C "$flake" diff --name-only "$(git -C "$flake" merge-base "$running" "$final")" "$running")
fi
if [ "${#onlyPaths[@]}" -eq 0 ]; then
  base=$final
  rev=$final
  echo "building ${final:0:7} ($(git -C "$flake" log -1 --format=%s "$final"))"
  if [ "${#carried[@]}" -gt 0 ]; then
    echo "warning: $rebuildTarget runs ${running:0:7}, whose snapshots carry work not on ${final:0:7}; deploying it drops it:" >&2
    printf '  %s\n' "${carried[@]}" >&2
  fi
else
  if [ -n "$baseArg" ]; then
    base=$(git -C "$flake" rev-parse --verify "$baseArg^{commit}") || exit 2
  else
    base=$running
    if [ "${#carried[@]}" -gt 0 ]; then
      echo "note: ${running:0:7} carries other snapshots' work not on HEAD; this build includes it:"
      printf '  %s\n' "${carried[@]}"
    fi
    if [ -z "$base" ]; then
      echo "warning: the revision $rebuildTarget runs is unknown here; building on HEAD" >&2
      base=$headRev
    fi
  fi
  echo "building on ${base:0:7} ($(git -C "$flake" log -1 --format=%s "$base"))"
  rev=$(snapshotRevision) || exit 1
fi
mapfile -t included < <([ "${#onlyPaths[@]}" -gt 0 ] && dirtyPaths -- "${onlyPaths[@]}")
mapfile -t leftOut < <(dirtyPaths | grep -vxF -f <(printf '%s\n' "${included[@]}" "") || true)
if [ "${#included[@]}" -gt 0 ]; then
  echo "uncommitted work included:"
  printf '  %s\n' "${included[@]}"
fi
if [ "${#leftOut[@]}" -gt 0 ]; then
  echo "uncommitted work left out (add it with --only PATH):"
  printf '  %s\n' "${leftOut[@]}"
fi
deployRef="refs/deploys/$rebuildTarget"
previouslyDeployed=$(git -C "$flake" rev-parse -q --verify "$deployRef" 2>/dev/null || true)
if [ "$rev" != "$base" ]; then
  echo "snapshot ${rev:0:7} on ${base:0:7}:"
  git -C "$flake" diff --stat "$base" "$rev" | sed 's/^/  /'
fi
if [ "$rev" = "$headRev" ]; then
  source="git+file://$flake?rev=$rev"
else
  snapshotRef="$deployRef.pending"
  git -C "$flake" update-ref "$snapshotRef" "$rev"
  source="git+file://$flake?ref=$snapshotRef&rev=$rev"
fi

srcPath=$(nix eval --impure --raw --expr "(builtins.fetchGit { url = \"$flake\"; rev = \"$rev\"; allRefs = true; }).outPath") || exit 1
pinArgs=()
pinOut=$(nix eval --raw --impure --expr "let p = import \"$srcPath/lib/pins.nix\" { root = \"$srcPath\"; host = \"$rebuildTarget\"; }; in builtins.concatStringsSep \"\\n\" p.argv") || exit 1
[ -n "$pinOut" ] && mapfile -t pinArgs <<< "$pinOut"
opts+=("${pinArgs[@]}")

recordDeployed() {
  git -C "$flake" update-ref "$deployRef" "$rev"
  if [ "$rev" != "$base" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    git -C "$flake" update-ref "refs/sessions/$CLAUDE_CODE_SESSION_ID/$rebuildTarget" "$rev"
  fi
  if ! git -C "$flake" push -q --force origin "$rev:$deployRef" 2>/dev/null; then
    echo "warning: could not push $deployRef to origin; other machines cannot inspect this deploy" >&2
  fi
  publishDeploy
}

publishDeploy() {
  local branch snapshot=0
  branch=$(git -C "$flake" symbolic-ref --short -q HEAD || echo detached)
  [ "$rev" = "$base" ] || snapshot=1
  printf 'fleet_deploy_seconds{rev="%s",branch="%s",snapshot="%s",action="%s"} %s\n' \
    "$rev" "$branch" "$snapshot" "$action" "$(date +%s)" \
    | curl -fsS -m 5 --data-binary @- \
      "http://${FLEET_PUSHGATEWAY:-pi:9093}/metrics/job/fleet_deploy/instance/$rebuildTarget" >/dev/null \
    || echo "warning: could not publish the deploy record to the pushgateway" >&2
}

repo_git() { git -C "$flake" "$@"; }

check_running() {
  local node=$1 running=${2%-dirty} base
  [ -n "$running" ] && [ "$running" != "$rev" ] || return 0
  if ! repo_git cat-file -e "$running^{commit}" 2>/dev/null; then
    echo "warning: $node runs $running, a commit this clone does not have; deploying over it blind" >&2
    return 0
  fi
  base=$(upgrade_base "$running")
  if [ "$base" != "$running" ] && ! repo_git diff --quiet "$running" "$rev" -- flake.lock; then
    echo "note: $node runs the auto-upgrade ${running:0:7}; ${rev:0:7} replaces its inputs with its own flake.lock" >&2
  fi
  repo_git merge-base --is-ancestor "$base" "$rev" && return 0
  [ "$running" = "$previouslyDeployed" ] && return 0
  [ "$supersede" = 1 ] && return 0
  echo "error: $node runs ${running:0:7} ($(repo_git log -1 --format=%s "$running")), which ${rev:0:7} does not descend from." >&2
  echo "  It was deployed from elsewhere. Pass --supersede to replace it, or land it first." >&2
  exit 3
}

claim_or_exit() {
  claim_deploy "$1" "$rev" "deploying ${rev:0:7} to $1 from $host${CLAUDE_CODE_SESSION_ID:+ (claude $CLAUDE_CODE_SESSION_ID)}" "$supersede" && return 0
  echo "  Wait for it, or pass --supersede to deploy over it." >&2
  exit 75
}

if [ -n "$target" ]; then
  deployOpts=()
  case "$action" in
    switch) ;;
    boot) deployOpts+=(--boot) ;;
    test) deployOpts+=(--test) ;;
    dry-activate) deployOpts+=(--dry-activate) ;;
    home) echo "error: --host deploys the home profile alongside the system" >&2; exit 2 ;;
    *) echo "error: $action is not a deploy action" >&2; exit 2 ;;
  esac

  exec 9>>"$stateDir/$target.lock"
  if ! flock -n 9; then
    echo "error: another deploy to $target is running: $(cat "$stateDir/$target.lock" 2>/dev/null)" >&2
    exit 75
  fi
  printf 'pid %s since %s\n' $$ "$(date -Is)" > "$stateDir/$target.lock"

  if activating; then
    claim_or_exit "$target"
    git -C "$flake" fetch -q origin '+refs/deploys/*:refs/remotes/deploys/*' 2>/dev/null || true
    check_running "$target" "$(timeout 20 ssh -o BatchMode=yes "$target" nixos-version --configuration-revision 2>/dev/null || true)"
  fi

  export NIX_CONFIG="accept-flake-config = true
eval-cache = false"

  # shellcheck disable=SC2194
  case " $REBUILD_WAKE_PEERS " in
    *" $target "*)
      if command -v wake-peer >/dev/null 2>&1; then
        wake-peer "$target" || echo "warning: could not wake $target" >&2
      fi ;;
  esac

  deployTarget="$source#$target"
  [ -n "$profile" ] && deployTarget="$source#$target.$profile"

  live=$(timeout 30 ssh -o BatchMode=yes "$target" 'readlink -f /run/current-system ~/.local/state/nix/profiles/home-manager 2>/dev/null' 2>/dev/null || true)
  if [ -n "$live" ]; then
    echo "seeding the store with what $target runs"
    # shellcheck disable=SC2086
    nix copy --no-check-sigs --from "ssh://$target" $live || echo "warning: could not copy $target's live closure; unchanged paths may rebuild" >&2
  fi

  rootsDir="$stateDir/roots"
  mkdir -p "$rootsDir"
  rootProfiles=(system home)
  [ -n "$profile" ] && rootProfiles=("$profile")
  for rootProfile in "${rootProfiles[@]}"; do
    echo "building $target $rootProfile profile, rooted at $rootsDir/$target-$rootProfile"
    nix build --out-link "$rootsDir/$target-$rootProfile" "${pinArgs[@]}" "$source#deploy.nodes.$target.profiles.$rootProfile.path"
  done

  deployAuthOpts=()
  if [ "${REBUILD_SSH_AGENT_SUDO:-0}" = 1 ]; then
    deployAuthOpts+=(--interactive-sudo false)
  fi

  deployBuildOpts=()
  [ "${#pinArgs[@]}" -gt 0 ] && deployBuildOpts=(-- "${pinArgs[@]}")

  printf -v deployCmd '%q ' nix run "$source#deploy-rs" -- \
    --skip-checks "${deployAuthOpts[@]}" "$deployTarget" "${deployOpts[@]}" "$@" "${deployBuildOpts[@]}"

  status=0
  if getent group novpn >/dev/null 2>&1; then
    /run/wrappers/bin/sg novpn -c "$deployCmd" || status=$?
  else
    bash -c "$deployCmd" || status=$?
  fi
  [ "$status" -eq 0 ] || exit "$status"

  case "$action" in
    switch|test)
      now=$(timeout 30 ssh -o BatchMode=yes "$target" nixos-version --configuration-revision 2>/dev/null || true)
      failed=$(timeout 30 ssh -o BatchMode=yes "$target" systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd, || true)
      if [ "$now" = "$rev" ]; then
        recordDeployed
        echo "VERIFIED: $target runs ${rev:0:7}${failed:+; failed units: $failed}"
      else
        echo "ROLLED BACK: $target runs ${now:-unknown}, expected ${rev:0:7}" >&2
        exit 4
      fi ;;
    boot) recordDeployed; echo "STAGED: ${rev:0:7} becomes current on the next boot of $target" ;;
  esac
  if activating && [ "$rev" != "$base" ]; then
    echo "deployed snapshot ${rev:0:7} to $target; uncommitted: $(git -C "$flake" diff --shortstat "$base" "$rev")"
    echo "  commit it as one change when verified, or leave it: deploy-status reports it."
  fi
  exit 0
fi

case "$action" in
  switch|boot)
    if [ -n "${SSH_CONNECTION:-}" ]; then
      echo "error: remote session; activating here has no rollback guarantee" >&2
      echo "  from your workstation: rebuild --host $host $action" >&2
      exit 1
    fi ;;
esac

case "$action" in
  home)
    export NIX_OBSERVER_KIND=home-rebuild
    rebuildKind=home-rebuild
    home-manager switch --flake "$source#max@$host" "${opts[@]}" "$@" ;;
  build|dry-build|repl)
    nixos-rebuild "$action" --flake "$source#$host" "${opts[@]}" "$@" ;;
  switch|boot|test|dry-activate)
    if activating; then
      claim_or_exit "$host"
      git -C "$flake" fetch -q origin '+refs/deploys/*:refs/remotes/deploys/*' 2>/dev/null || true
      check_running "$host" "$(nixos-version --configuration-revision 2>/dev/null || true)"
    fi
    nixos-rebuild build --flake "$source#$host" "${opts[@]}" "$@"
    sudo nixos-rebuild "$action" --flake "$source#$host" "${opts[@]}" "$@"
    activating && recordDeployed
    if activating && [ "$rev" != "$base" ]; then
      echo "activated snapshot ${rev:0:7}; uncommitted: $(git -C "$flake" diff --shortstat "$base" "$rev")"
    fi ;;
  *)
    sudo nixos-rebuild "$action" --flake "$source#$host" "${opts[@]}" "$@" ;;
esac

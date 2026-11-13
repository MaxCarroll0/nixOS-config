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
               [--note TEXT] [--supersede] [--log PATH] [ACTION] [nixos-rebuild args]

ACTION defaults to switch. Local: switch boot test dry-activate build dry-build repl home.
Remote (--host): switch boot test dry-activate.

A dirty tree is deployed as a snapshot commit on refs/deploys/NODE, pushed to origin, so the
target's configuration revision is always a real commit. --note labels that snapshot.
--supersede deploys over a revision deployed from another machine.
EOF
}

target=""
profile=""
note=""
supersede=0
logPath=""
while true; do
  case "${1:-}" in
    --local) opts+=(--option builders ""); shift ;;
    --mixed) opts+=(--option builders "@/etc/nix/machines"); shift ;;
    --host) target="${2:?--host needs a node name}"; shift 2 ;;
    --profile) profile="${2:?--profile needs system or home}"; shift 2 ;;
    --note) note="${2:?--note needs text}"; shift 2 ;;
    --supersede) supersede=1; shift ;;
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

snapshotRevision() {
  local index tree head subject
  head=$(git -C "$flake" rev-parse HEAD)
  index=$(mktemp)
  trap 'rm -f "$index"' RETURN
  GIT_INDEX_FILE=$index git -C "$flake" read-tree HEAD
  GIT_INDEX_FILE=$index git -C "$flake" -c advice.addIgnoredFile=false add -A >/dev/null
  tree=$(GIT_INDEX_FILE=$index git -C "$flake" write-tree)
  if [ "$tree" = "$(git -C "$flake" rev-parse 'HEAD^{tree}')" ]; then
    echo "$head"
    return
  fi
  subject="snapshot: $rebuildTarget $action${note:+ ($note)}"
  GIT_INDEX_FILE=$index git -C "$flake" commit-tree "$tree" -p "$head" -m "$subject" \
    -m "$(GIT_INDEX_FILE=$index git -C "$flake" diff --cached --stat HEAD)"
}

rev=$(snapshotRevision)
headRev=$(git -C "$flake" rev-parse HEAD)
deployRef="refs/deploys/$rebuildTarget"
if [ "$rev" != "$headRev" ]; then
  echo "snapshot ${rev:0:7} (tree differs from HEAD ${headRev:0:7}):"
  git -C "$flake" diff --stat HEAD "$rev" | sed 's/^/  /'
fi
if [ "$rev" = "$headRev" ]; then
  source="git+file://$flake?rev=$rev"
else
  snapshotRef="$deployRef.pending"
  activating && snapshotRef="$deployRef"
  git -C "$flake" update-ref "$snapshotRef" "$rev"
  if activating && ! git -C "$flake" push -q --force origin "$rev:$deployRef" 2>/dev/null; then
    echo "warning: could not push $deployRef to origin; other machines cannot inspect this deploy" >&2
  fi
  source="git+file://$flake?ref=$snapshotRef&rev=$rev"
fi

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

  exec 9>"$stateDir/$target.lock"
  if ! flock -n 9; then
    echo "error: another deploy to $target is running: $(cat "$stateDir/$target.lock" 2>/dev/null)" >&2
    exit 75
  fi
  printf 'pid %s since %s\n' $$ "$(date -Is)" >&9

  if activating; then
    git -C "$flake" fetch -q origin '+refs/deploys/*:refs/remotes/deploys/*' 2>/dev/null || true
    running=$(timeout 20 ssh -o BatchMode=yes "$target" nixos-version --configuration-revision 2>/dev/null || true)
    running=${running%-dirty}
    if [ -n "$running" ] && [ "$running" != "$rev" ]; then
      if ! git -C "$flake" cat-file -e "$running^{commit}" 2>/dev/null; then
        echo "warning: $target runs $running, a commit this clone does not have; deploying over it blind" >&2
      elif ! git -C "$flake" merge-base --is-ancestor "$running" "$rev" \
          && [ "$running" != "$(git -C "$flake" rev-parse -q --verify "$deployRef@{0}" 2>/dev/null || true)" ] \
          && [ "$supersede" = 0 ]; then
        echo "error: $target runs ${running:0:7} ($(git -C "$flake" log -1 --format=%s "$running")), which ${rev:0:7} does not descend from." >&2
        echo "  It was deployed from elsewhere. Pass --supersede to replace it, or land it first." >&2
        exit 3
      fi
    fi
  fi

  export NIX_CONFIG="accept-flake-config = true"

  # shellcheck disable=SC2194
  case " $REBUILD_WAKE_PEERS " in
    *" $target "*)
      if command -v wake-peer >/dev/null 2>&1; then
        wake-peer "$target" || echo "warning: could not wake $target" >&2
      fi ;;
  esac

  deployTarget="$source#$target"
  [ -n "$profile" ] && deployTarget="$source#$target.$profile"

  deployAuthOpts=()
  if [ "${REBUILD_SSH_AGENT_SUDO:-0}" = 1 ]; then
    deployAuthOpts+=(--interactive-sudo false)
  fi

  printf -v deployCmd '%q ' nix run "$source#deploy-rs" -- \
    --skip-checks "${deployAuthOpts[@]}" "$deployTarget" "${deployOpts[@]}" "$@"

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
        echo "VERIFIED: $target runs ${rev:0:7}${failed:+; failed units: $failed}"
      else
        echo "ROLLED BACK: $target runs ${now:-unknown}, expected ${rev:0:7}" >&2
        exit 4
      fi ;;
    boot) echo "STAGED: ${rev:0:7} becomes current on the next boot of $target" ;;
  esac
  if activating && [ "$rev" != "$headRev" ]; then
    echo "deployed snapshot ${rev:0:7} to $target; uncommitted: $(git -C "$flake" diff --shortstat HEAD "$rev")"
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
    nixos-rebuild build --flake "$source#$host" "${opts[@]}" "$@"
    sudo nixos-rebuild "$action" --flake "$source#$host" "${opts[@]}" "$@"
    if activating && [ "$rev" != "$headRev" ]; then
      echo "activated snapshot ${rev:0:7}; uncommitted: $(git -C "$flake" diff --shortstat HEAD "$rev")"
    fi ;;
  *)
    sudo nixos-rebuild "$action" --flake "$source#$host" "${opts[@]}" "$@" ;;
esac

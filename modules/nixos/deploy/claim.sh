claimStale=10800
claimRef=""
claimCommit=""

claim_deploy() {
  local node=$1 rev=$2 message=$3 force=${4:-0} remote existing age subject
  claimRef=refs/deploying/$node
  if ! remote=$(repo_git ls-remote origin "$claimRef"); then
    echo "warning: origin unreachable; activating $node without claiming it" >&2
    return 0
  fi
  existing=$(cut -f1 <<<"$remote")
  if [ -n "$existing" ]; then
    repo_git fetch -q origin "+$claimRef:refs/remotes/deploying/$node"
    age=$(($(date +%s) - $(repo_git log -1 --format=%ct "refs/remotes/deploying/$node")))
    subject=$(repo_git log -1 --format=%s "refs/remotes/deploying/$node")
    if [ "$age" -lt "$claimStale" ] && [ "$force" = 0 ]; then
      echo "$node is claimed $((age / 60)) min ago: $subject" >&2
      return 1
    fi
    echo "warning: replacing the claim on $node: $subject" >&2
  fi
  claimCommit=$(repo_git commit-tree "$rev^{tree}" -p "$rev" -m "$message")
  if ! repo_git push -q --force-with-lease="$claimRef:$existing" origin "$claimCommit:$claimRef"; then
    claimCommit=""
    echo "$node was claimed by another deploy just now" >&2
    return 1
  fi
}

release_deploy() {
  [ -n "$claimCommit" ] || return 0
  repo_git push -q --force-with-lease="$claimRef:$claimCommit" origin ":$claimRef" 2>/dev/null \
    || echo "warning: could not release $claimRef" >&2
  claimCommit=""
}

upgrade_base() {
  local rev=$1
  while [[ "$(repo_git log -1 --format=%s "$rev")" == "upgrade: "* ]]; do
    rev=$(repo_git rev-parse "$rev^")
  done
  echo "$rev"
}

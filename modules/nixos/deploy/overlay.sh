worktreeBase() {
  local vb head old index path mode blob kept=0
  head=$(git -C "$flake" rev-parse HEAD)
  vb=$(git -C "$flake" rev-parse -q --verify refs/worktree/base 2>/dev/null || true)
  if [ -z "$vb" ]; then
    echo "$head"
    return
  fi
  old=$(git -C "$flake" rev-parse "$vb^")
  if [ "$old" = "$head" ]; then
    echo "$vb"
    return
  fi
  index=$(mktemp)
  GIT_INDEX_FILE=$index git -C "$flake" read-tree "$head"
  while IFS= read -r -d '' path; do
    [ "$(git -C "$flake" rev-parse -q --verify "$old:$path" 2>/dev/null || true)" = "$(git -C "$flake" rev-parse -q --verify "$head:$path" 2>/dev/null || true)" ] || continue
    read -r mode _ blob _ < <(git -C "$flake" ls-tree "$vb" -- "$path")
    if [ -n "${blob:-}" ]; then
      GIT_INDEX_FILE=$index git -C "$flake" update-index --add --cacheinfo "$mode,$blob,$path"
    else
      GIT_INDEX_FILE=$index git -C "$flake" update-index --force-remove -- "$path"
    fi
    blob=""
    kept=1
  done < <(git -C "$flake" diff --name-only -z "$old" "$vb")
  if [ "$kept" = 1 ]; then
    vb=$(git -C "$flake" commit-tree "$(GIT_INDEX_FILE=$index git -C "$flake" write-tree)" -p "$head" -m "worktree base: HEAD plus landed paths")
    git -C "$flake" update-ref refs/worktree/base "$vb"
    echo "$vb"
  else
    git -C "$flake" update-ref -d refs/worktree/base
    echo "$head"
  fi
  rm -f "$index"
}

recordLanded() {
  local commit=$1 vb index path mode blob
  shift
  vb=$(worktreeBase)
  index=$(mktemp)
  GIT_INDEX_FILE=$index git -C "$flake" read-tree "$vb"
  for path in "$@"; do
    read -r mode _ blob _ < <(git -C "$flake" ls-tree "$commit" -- "$path")
    if [ -n "${blob:-}" ]; then
      GIT_INDEX_FILE=$index git -C "$flake" update-index --add --cacheinfo "$mode,$blob,$path"
    else
      GIT_INDEX_FILE=$index git -C "$flake" update-index --force-remove -- "$path"
    fi
    blob=""
  done
  git -C "$flake" update-ref refs/worktree/base \
    "$(git -C "$flake" commit-tree "$(GIT_INDEX_FILE=$index git -C "$flake" write-tree)" -p HEAD -m "worktree base: HEAD plus landed paths")"
  rm -f "$index"
}

overlayOnto() {
  local base=$1 index=$2 work patch path mode blob had from
  shift 2
  from=$(worktreeBase)
  work=$(mktemp)
  patch=$(mktemp)
  GIT_INDEX_FILE=$work git -C "$flake" read-tree "$from"
  if ! GIT_INDEX_FILE=$work git -C "$flake" -c advice.addIgnoredFile=false add -A -- "$@" >/dev/null; then
    rm -f "$work" "$patch"
    return 1
  fi
  GIT_INDEX_FILE=$work git -C "$flake" diff --cached --binary --diff-filter=a "$from" > "$patch"
  GIT_INDEX_FILE=$index git -C "$flake" read-tree "$base"
  if [ -s "$patch" ] && ! GIT_INDEX_FILE=$index git -C "$flake" apply --cached --3way "$patch" >&2; then
    rm -f "$work" "$patch"
    return 1
  fi
  while IFS= read -r -d '' path; do
    read -r mode blob _ < <(GIT_INDEX_FILE=$work git -C "$flake" ls-files -s -- "$path")
    had=$(git -C "$flake" rev-parse -q --verify "$base:$path" 2>/dev/null || true)
    if [ -n "$had" ] && [ "$had" != "$blob" ]; then
      echo "warning: $path is new to this clone but ${base:0:7} has another copy of it; using this clone's" >&2
    fi
    GIT_INDEX_FILE=$index git -C "$flake" update-index --add --cacheinfo "$mode,$blob,$path"
  done < <(GIT_INDEX_FILE=$work git -C "$flake" diff --cached --name-only -z --diff-filter=A "$from")
  rm -f "$work" "$patch"
}

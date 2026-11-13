branch=$1
cd "$branch"
declare -A last_warm
warmed_files=0
warmed_bytes=0
skipped=0

publish() {
  tmp=@metricsFile@.$$
  label=$(basename "$branch")
  {
    echo '# HELP nas_prefetch_files_total Files read ahead after a sibling was opened.'
    echo '# TYPE nas_prefetch_files_total counter'
    echo "nas_prefetch_files_total{branch=\"$label\"} $warmed_files"
    echo '# HELP nas_prefetch_bytes_total Bytes read ahead.'
    echo '# TYPE nas_prefetch_bytes_total counter'
    echo "nas_prefetch_bytes_total{branch=\"$label\"} $warmed_bytes"
    echo '# HELP nas_prefetch_skipped_total Opens ignored because the folder was still in cooldown.'
    echo '# TYPE nas_prefetch_skipped_total counter'
    echo "nas_prefetch_skipped_total{branch=\"$label\"} $skipped"
  } > "$tmp"
  mv "$tmp" @metricsFile@
}

trap 'publish; exit 0' EXIT TERM INT

while IFS= read -r line; do
  case $line in *'"path":"'*) ;; *) continue ;; esac
  path=${line#*'"path":"'}
  path=${path%%'"'*}
  case $path in "$branch"/*) ;; *) continue ;; esac

  comm=${line#*'"comm":"'}
  comm=${comm%%'"'*}
  case $comm in @ignoreCommands@) continue ;; esac

  dir=$(dirname "$path")
  now=$(date +%s)
  prev=${last_warm[$dir]:-0}
  if [ $((now - prev)) -lt @cooldownSeconds@ ]; then
    skipped=$((skipped + 1))
    if [ $((skipped % 50)) -eq 0 ]; then publish; fi
    continue
  fi
  last_warm[$dir]=$now

  budget=@maxBytes@
  count=0
  while IFS= read -r sib; do
    if [ "$sib" = "$path" ]; then continue; fi
    if [ "$count" -ge @maxFiles@ ]; then break; fi
    size=$(stat -c %s "$sib" 2>/dev/null || echo 0)
    if [ "$size" -le 0 ] || [ "$size" -gt "$budget" ]; then continue; fi
    if dd if="$sib" of=/dev/null bs=1M status=none 2>/dev/null; then
      count=$((count + 1))
      budget=$((budget - size))
      warmed_files=$((warmed_files + 1))
      warmed_bytes=$((warmed_bytes + size))
    fi
  done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)

  publish
done < <(fatrace -c -f O -j -t -t)

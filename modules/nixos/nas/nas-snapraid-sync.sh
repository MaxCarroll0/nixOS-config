for m in @dataMounts@ @parityMount@; do
  mountpoint -q "$m" || exit 0
done

for dev in @arrayDevices@; do
  [ -b "$dev" ] || continue
  rc=0
  out=$(smartctl -H -A "$dev") || rc=$?
  case "$out" in
    *"test result: PASSED"*) ;;
    *) echo "refusing to sync: $dev does not report SMART PASSED" >&2; exit 1 ;;
  esac

  # smartctl bit 3 is DISK FAILING and bit 4 a pre-fail attribute; bit 5 (usage) must not block parity.
  if [ $((rc & 8)) -ne 0 ] || [ $((rc & 16)) -ne 0 ]; then
    echo "refusing to sync: $dev reports a failing pre-fail attribute" >&2
    exit 1
  fi

  unresolved=$(printf '%s\n' "$out" | awk '($1 == "197" || $1 == "198") && $10 + 0 > 0 { print $2 "=" $10 }')
  if [ -n "$unresolved" ]; then
    echo "refusing to sync: $dev has unresolved media faults: $unresolved" >&2
    exit 1
  fi

  if [ $((rc & 32)) -ne 0 ]; then
    echo "note: $dev has a historic usage counter past threshold" >&2
  fi
done

snapraid --conf @snapraidConf@ touch

# diff exits non-zero on any difference, so the gate reads the counts, not the status.
diff_out=$(snapraid --conf @snapraidConf@ diff || true)
removed=$(printf '%s\n' "$diff_out" | awk '$2 == "removed" { print $1; exit }')
updated=$(printf '%s\n' "$diff_out" | awk '$2 == "updated" { print $1; exit }')
removed=${removed:-0}
updated=${updated:-0}
echo "diff: removed=$removed updated=$updated"

if [ "$removed" -gt @maxRemoved@ ] || [ "$updated" -gt @maxUpdated@ ]; then
  echo "refusing to sync: removed=$removed (max @maxRemoved@), updated=$updated (max @maxUpdated@)." >&2
  echo "Parity still reflects the previous state. Investigate, then run snapraid sync by hand if this was intended." >&2
  exit 1
fi

flock @nilfsWriteLock@ snapraid --conf @snapraidConf@ sync

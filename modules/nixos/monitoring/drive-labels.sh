declare -A labels
echo '# HELP drive_label_info Persistent name of a block device: its role or model, and its size.'
echo '# TYPE drive_label_info gauge'
for path in /sys/block/*; do
  device=${path##*/}
  case "$device" in
    loop* | ram* | zram* | sr* | fd*) continue ;;
  esac
  gb=$(($(cat "$path/size") * 512 / 1000000000))
  [ "$gb" -gt 0 ] || continue
  if [ -r "$path/dm/name" ]; then
    role=$(cat "$path/dm/name")
  else
    role=$(lsblk -nro NAME,TYPE "/dev/$device" | awk '$2 == "crypt" && sub(/^nas-/, "", $1) { print $1; exit }')
    if [ -z "$role" ] && lsblk -nro MOUNTPOINTS "/dev/$device" | awk -F '\\\\x0a' '{ for (i = 1; i <= NF; i++) if ($i == "/") found = 1 } END { exit !found }'; then
      role=system
    fi
    [ -n "$role" ] || role=$(awk '{ $1 = $1; print }' "$path/device/model" 2>/dev/null || true)
    [ -n "$role" ] || role=$device
  fi
  labels[$device]="${role//\"/} $gb GB"
  printf 'drive_label_info{device="%s",drive="%s"} 1\n' "$device" "${labels[$device]}"
done

echo '# HELP drive_hwmon_info Drive a drivetemp hwmon chip belongs to.'
echo '# TYPE drive_hwmon_info gauge'
for hwmon in /sys/class/hwmon/hwmon*; do
  [ "$(cat "$hwmon/name" 2>/dev/null)" = drivetemp ] || continue
  for block in "$hwmon"/device/block/*; do
    device=${block##*/}
    [ -n "${labels[$device]:-}" ] || continue
    parent=$(realpath "$hwmon/device")
    chip="$(basename "$(dirname "$parent")")_$(basename "$parent")"
    printf 'drive_hwmon_info{chip="%s",drive="%s"} 1\n' "$chip" "${labels[$device]}"
  done
done

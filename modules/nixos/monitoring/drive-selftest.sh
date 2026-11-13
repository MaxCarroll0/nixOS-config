mkdir -p @stateDir@
now=$(date +%s)
hour=$(date +%-H)

# A drive first seen now is not overdue: without this every drive is
# instantly due on install and starts a multi-hour test immediately.
since_seen() {
  local file=$1
  [ -s "$file" ] || printf '%s' "$now" > "$file"
  cat "$file"
}

parked() {
  awk -v d="$1" '$0 ~ "^pc_disk_standby\\{device=\"" d "\"\\}" { print ($NF == 1) ? 1 : 0; found=1 }
    END { if (!found) print 0 }' \
    @textfileDir@/power-model.prom 2>/dev/null || echo 0
}

in_window() {
  local from=@fromHour@
  local to=@toHour@
  if [ "$from" -le "$to" ]; then
    [ "$hour" -ge "$from" ] && [ "$hour" -lt "$to" ]
  else
    [ "$hour" -ge "$from" ] || [ "$hour" -lt "$to" ]
  fi
}

@probe@

exec 9>@stateDir@/.selftest.lock
flock -n 9 || exit 0

for path in /sys/block/*; do
  device=${path##*/}
  @skipDevices@
  [ -e "$path/device" ] || continue
  [ "$(cat "$path/queue/rotational" 2>/dev/null || echo 0)" = 1 ] || continue

  last_long=$(since_seen "@stateDir@/$device.long")
  last_short=$(since_seen "@stateDir@/$device.short")

  io=$(awk -v d="$device" '$3 == d { print $6 + $10 }' /proc/diskstats)
  was=$(cat "@stateDir@/$device.testio" 2>/dev/null || true)
  printf '%s' "$io" > "@stateDir@/$device.testio"
  idle_since=$(cat "@stateDir@/$device.idle" 2>/dev/null || echo "$now")
  if [ "$io" != "$was" ]; then
    printf '%s' "$now" > "@stateDir@/$device.idle"
    idle_since=$now
  fi

  long_due=0
  [ "$((now - last_long))" -ge @longSeconds@ ] && in_window && long_due=1

  short_due=0
  [ "$((now - idle_since))" -ge @preSpindownSeconds@ ] \
    && [ "$((now - last_short))" -ge @shortSeconds@ ] \
    && short_due=1

  if [ "$long_due" = 0 ] && [ "$short_due" = 0 ]; then
    continue
  fi

  if [ "$long_due" = 0 ] && [ "$(parked "$device")" = 1 ]; then
    continue
  fi

  if probe "$device" -j -c \
    | jq -e '.ata_smart_data.self_test.status.remaining_percent' >/dev/null 2>&1; then
    continue
  fi

  if [ "$long_due" = 1 ]; then
    probe_wake "$device" -t long > /dev/null
    printf '%s' "$now" > "@stateDir@/$device.long"
  else
    probe "$device" -t short > /dev/null
    printf '%s' "$now" > "@stateDir@/$device.short"
  fi
  exit 0
done

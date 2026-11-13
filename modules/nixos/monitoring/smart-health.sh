mkdir -p @stateDir@
now=$(date +%s)

echo '# HELP smart_health_ok Drive self-assessment, 1 when passing.'
echo '# TYPE smart_health_ok gauge'
echo '# HELP smart_attribute_raw Raw value of a SMART attribute.'
echo '# TYPE smart_attribute_raw gauge'
echo '# HELP smart_attribute_value Normalised value of a SMART attribute.'
echo '# TYPE smart_attribute_value gauge'
echo '# HELP smart_attribute_threshold Vendor failure threshold for a SMART attribute.'
echo '# TYPE smart_attribute_threshold gauge'
echo '# HELP smart_sample_age_seconds Age of the last successful read of this drive.'
echo '# TYPE smart_sample_age_seconds gauge'
echo '# HELP smart_selftest_status Result of the last self-test, 0 when it passed.'
echo '# TYPE smart_selftest_status gauge'

@probe@

for path in /sys/block/*; do
  device=${path##*/}
  @skipDevices@
  [ -e "$path/device" ] || continue

  cache=@stateDir@/$device.prom
  io=$(awk -v d="$device" '$3 == d { print $6 + $10 }' /proc/diskstats)
  [ -n "$io" ] || continue
  was=$(cat "@stateDir@/$device.io" 2>/dev/null || true)

  stamp=$(cat "@stateDir@/$device.ts" 2>/dev/null || echo 0)
  if [ "$io" = "$was" ] && [ -s "$cache" ] \
    && [ "$((now - stamp))" -lt @refreshSeconds@ ]; then
    cat "$cache"
    printf 'smart_sample_age_seconds{device="%s"} %s\n' "$device" "$((now - stamp))"
    continue
  fi

  report=$(probe "$device" -j -H -A -i -c)
  if printf '%s' "$report" | jq -e '[.smartctl.messages[]?.string] | any(test("STANDBY"))' >/dev/null 2>&1; then
    if [ -s "$cache" ]; then
      cat "$cache"
      stamp=$(cat "@stateDir@/$device.ts" 2>/dev/null || echo "$now")
      printf 'smart_sample_age_seconds{device="%s"} %s\n' "$device" "$((now - stamp))"
    fi
    printf '%s' "$io" > "@stateDir@/$device.io"
    continue
  fi

  fresh=$(mktemp)
  printf '%s' "$report" | jq -r --arg d "$device" '
    def esc: tostring | gsub("\\\\"; "") | gsub("\""; "");
    def dev: "device=\"\($d)\"";
    def attr(a): "device=\"\($d)\",id=\"\(a.id)\",name=\"\(a.name | esc)\"";

    "smart_device_info{\(dev),model=\"\(.model_name // "unknown" | esc)\""
      + ",serial=\"\(.serial_number // "unknown" | esc)\""
      + ",firmware=\"\(.firmware_version // "unknown" | esc)\""
      + ",rotational=\"\(if (.rotation_rate // 0) > 0 then 1 else 0 end)\"} 1",

    (if .smart_status.passed == null then empty
     else "smart_health_ok{\(dev)} \(if .smart_status.passed then 1 else 0 end)" end),
    (if .temperature.current == null then empty
     else "smart_temperature_celsius{\(dev)} \(.temperature.current)" end),
    (if .power_on_time.hours == null then empty
     else "smart_power_on_hours{\(dev)} \(.power_on_time.hours)" end),

    ((.ata_smart_attributes.table // [])[] |
      "smart_attribute_value{\(attr(.))} \(.value)",
      "smart_attribute_worst{\(attr(.))} \(.worst)",
      "smart_attribute_threshold{\(attr(.))} \(.thresh)",
      "smart_attribute_raw{\(attr(.))} \(.raw.value)"),

    (.nvme_smart_health_information_log // empty |
      "smart_nvme_used_ratio{\(dev)} \((.percentage_used // 0) / 100)",
      "smart_nvme_spare_ratio{\(dev)} \((.available_spare // 0) / 100)",
      "smart_nvme_written_bytes{\(dev)} \((.data_units_written // 0) * 512000)",
      "smart_nvme_media_errors{\(dev)} \(.media_errors // 0)",
      "smart_nvme_unsafe_shutdowns{\(dev)} \(.unsafe_shutdowns // 0)"),

    (.ata_smart_data.self_test.status // empty |
      "smart_selftest_status{\(dev)} \(.value)",
      (if .remaining_percent == null then empty
       else "smart_selftest_remaining_ratio{\(dev)} \(.remaining_percent / 100)" end)),

    (if .ata_smart_data.self_test.polling_minutes == null then empty
     else "smart_selftest_minutes{\(dev),kind=\"short\"} \(.ata_smart_data.self_test.polling_minutes.short // 0)",
          "smart_selftest_minutes{\(dev),kind=\"extended\"} \(.ata_smart_data.self_test.polling_minutes.extended // 0)" end)
  ' > "$fresh" 2>/dev/null || true

  if [ -s "$fresh" ]; then
    mv "$fresh" "$cache"
    printf '%s' "$now" > "@stateDir@/$device.ts"
    cat "$cache"
    printf 'smart_sample_age_seconds{device="%s"} 0\n' "$device"
  else
    rm -f "$fresh"
  fi
  printf '%s' "$io" > "@stateDir@/$device.io"
done

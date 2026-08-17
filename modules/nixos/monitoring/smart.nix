# SMART health and scheduled self-tests, without ever waking a parked drive.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.monitoring.smart;

  collectors = import ./collector-lib.nix { inherit pkgs lib; };
  inherit (collectors) writeCollector collectorService collectorTimer;

  stateDir = "/var/lib/smart-health";

  skipDevices = ''
    case "$device" in
      loop* | ram* | zram* | dm-* | md* | sr* | fd*) continue ;;
    esac
  '';

  probe = ''
    smart_mode() {
      local dev=$1
      local mode
      mode=$(cat "${stateDir}/$dev.mode" 2>/dev/null || true)
      if [ -n "$mode" ]; then
        printf '%s' "$mode"
        return 0
      fi
      if smartctl -n standby -j -i "/dev/$dev" 2>/dev/null | jq -e '.model_name' >/dev/null 2>&1; then
        mode=auto
      elif smartctl -n standby -j -d sat -i "/dev/$dev" 2>/dev/null | jq -e '.model_name' >/dev/null 2>&1; then
        mode=sat
      else
        return 1
      fi
      printf '%s' "$mode" > "${stateDir}/$dev.mode"
      printf '%s' "$mode"
    }

    probe() {
      local dev=$1
      shift
      local mode
      mode=$(smart_mode "$dev") || {
        printf '{"smartctl":{"messages":[{"string":"Device is in STANDBY mode"}]}}\n'
        return 0
      }
      if [ "$mode" = sat ]; then
        smartctl -n standby -d sat "$@" "/dev/$dev" 2>&1 || true
      else
        smartctl -n standby "$@" "/dev/$dev" 2>&1 || true
      fi
    }

    probe_wake() {
      local dev=$1
      shift
      local mode
      mode=$(cat "${stateDir}/$dev.mode" 2>/dev/null || echo auto)
      if [ "$mode" = sat ]; then
        smartctl -d sat "$@" "/dev/$dev" 2>&1 || true
      else
        smartctl "$@" "/dev/$dev" 2>&1 || true
      fi
    }
  '';

  smartHealth =
    writeCollector "smart-health"
      [
        pkgs.smartmontools
        pkgs.gawk
        pkgs.jq
      ]
      ''
        mkdir -p ${stateDir}
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

        ${probe}

        for path in /sys/block/*; do
          device=''${path##*/}
          ${skipDevices}
          [ -e "$path/device" ] || continue

          cache=${stateDir}/$device.prom
          io=$(awk -v d="$device" '$3 == d { print $6 + $10 }' /proc/diskstats)
          [ -n "$io" ] || continue
          was=$(cat "${stateDir}/$device.io" 2>/dev/null || true)

          stamp=$(cat "${stateDir}/$device.ts" 2>/dev/null || echo 0)
          if [ "$io" = "$was" ] && [ -s "$cache" ] \
            && [ "$((now - stamp))" -lt ${toString (cfg.refreshMinutes * 60)} ]; then
            cat "$cache"
            printf 'smart_sample_age_seconds{device="%s"} %s\n' "$device" "$((now - stamp))"
            continue
          fi

          report=$(probe "$device" -j -H -A -i -c)
          if printf '%s' "$report" | jq -e '[.smartctl.messages[]?.string] | any(test("STANDBY"))' >/dev/null 2>&1; then
            if [ -s "$cache" ]; then
              cat "$cache"
              stamp=$(cat "${stateDir}/$device.ts" 2>/dev/null || echo "$now")
              printf 'smart_sample_age_seconds{device="%s"} %s\n' "$device" "$((now - stamp))"
            fi
            printf '%s' "$io" > "${stateDir}/$device.io"
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

            (.ata_smart_data.self_test_status // empty |
              "smart_selftest_status{\(dev)} \(.value)",
              (if .remaining_percent == null then empty
               else "smart_selftest_remaining_ratio{\(dev)} \(.remaining_percent / 100)" end))
          ' > "$fresh" 2>/dev/null || true

          if [ -s "$fresh" ]; then
            mv "$fresh" "$cache"
            printf '%s' "$now" > "${stateDir}/$device.ts"
            cat "$cache"
            printf 'smart_sample_age_seconds{device="%s"} 0\n' "$device"
          else
            rm -f "$fresh"
          fi
          printf '%s' "$io" > "${stateDir}/$device.io"
        done
      '';

  selfTest = pkgs.writeShellApplication {
    name = "drive-selftest";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.smartmontools
      pkgs.gawk
      pkgs.jq
      pkgs.util-linux
    ];
    text = ''
      mkdir -p ${stateDir}
      now=$(date +%s)
      hour=$(date +%-H)

      # A drive first seen now is not overdue: without this every drive is
      # instantly due on install and starts a multi-hour test immediately.
      since_seen() {
        local file=$1
        [ -s "$file" ] || printf '%s' "$now" > "$file"
        cat "$file"
      }

      in_window() {
        local from=${toString cfg.selfTest.longWindowFromHour}
        local to=${toString cfg.selfTest.longWindowToHour}
        if [ "$from" -le "$to" ]; then
          [ "$hour" -ge "$from" ] && [ "$hour" -lt "$to" ]
        else
          [ "$hour" -ge "$from" ] || [ "$hour" -lt "$to" ]
        fi
      }

      ${probe}

      exec 9>${stateDir}/.selftest.lock
      flock -n 9 || exit 0

      for path in /sys/block/*; do
        device=''${path##*/}
        ${skipDevices}
        [ -e "$path/device" ] || continue
        [ "$(cat "$path/queue/rotational" 2>/dev/null || echo 0)" = 1 ] || continue

        status=$(probe "$device" -j -c)
        running=$(printf '%s' "$status" \
          | jq -r '.ata_smart_data.self_test_status.remaining_percent // empty' 2>/dev/null || true)
        if [ -n "$running" ]; then
          continue
        fi

        last_long=$(since_seen "${stateDir}/$device.long")
        last_short=$(since_seen "${stateDir}/$device.short")

        if [ "$((now - last_long))" -ge ${
          toString (cfg.selfTest.longIntervalDays * 86400)
        } ] && in_window; then
          probe_wake "$device" -t long > /dev/null
          printf '%s' "$now" > "${stateDir}/$device.long"
          exit 0
        fi

        if printf '%s' "$status" \
          | jq -e '[.smartctl.messages[]?.string] | any(test("STANDBY"))' >/dev/null 2>&1; then
          continue
        fi

        io=$(awk -v d="$device" '$3 == d { print $6 + $10 }' /proc/diskstats)
        was=$(cat "${stateDir}/$device.testio" 2>/dev/null || true)
        printf '%s' "$io" > "${stateDir}/$device.testio"
        idle_since=$(cat "${stateDir}/$device.idle" 2>/dev/null || echo "$now")
        if [ "$io" != "$was" ]; then
          printf '%s' "$now" > "${stateDir}/$device.idle"
          continue
        fi

        if [ "$((now - idle_since))" -ge ${toString (cfg.selfTest.preSpindownMinutes * 60)} ] \
          && [ "$((now - last_short))" -ge ${toString (cfg.selfTest.shortIntervalHours * 3600)} ]; then
          probe "$device" -t short > /dev/null
          printf '%s' "$now" > "${stateDir}/$device.short"
          exit 0
        fi
      done
    '';
  };
in

{
  options.local.monitoring.smart = {
    enable = lib.mkEnableOption "SMART health collection";

    refreshMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Re-read a drive this long after the last successful read even with no I/O; parked drives still refuse.";
    };

    selfTest = {
      enable = lib.mkEnableOption "scheduled SMART self-tests";

      shortIntervalHours = lib.mkOption {
        type = lib.types.ints.positive;
        default = 24;
        description = "Minimum gap between short tests, which only run on an already-awake drive.";
      };

      longIntervalDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Gap between extended tests, which do wake a parked drive.";
      };

      longWindowFromHour = lib.mkOption {
        type = lib.types.ints.between 0 23;
        default = 1;
        description = "Hour after which an extended test may start.";
      };

      longWindowToHour = lib.mkOption {
        type = lib.types.ints.between 0 23;
        default = 6;
        description = "Hour after which an extended test may no longer start.";
      };

      preSpindownMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 55;
        description = "Idle minutes before a short test runs; keep just inside the hdparm -S timer, which is 60 minutes at 242.";
      };
    };
  };

  config = lib.mkIf (cfg.enable && config.local.monitoring.exporter.enable) (
    lib.mkMerge [
      {
        environment.systemPackages = [ pkgs.smartmontools ];
        systemd.tmpfiles.rules = [ "d ${stateDir} 0755 root root -" ];

        systemd.services.textfile-smart-health = lib.mkMerge [
          (collectorService smartHealth)
          {
            description = "Publish SMART health without waking idle disks";
            wantedBy = [ "multi-user.target" ];
          }
        ];

        systemd.timers.textfile-smart-health = collectorTimer "5m";
      }

      (lib.mkIf cfg.selfTest.enable {
        systemd.services.drive-selftest = {
          description = "Run due SMART self-tests when a drive is already spinning";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe selfTest;
          };
        };

        systemd.timers.drive-selftest = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "10m";
            OnUnitActiveSec = "5m";
            AccuracySec = "1m";
          };
        };
      })
    ]
  );
}

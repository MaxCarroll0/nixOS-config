# Textfile collectors feeding node_exporter: sensor names, tailnet peers, wireguard.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.monitoring;

  collectors = import ./collector-lib.nix { inherit pkgs lib; };
  inherit (collectors)
    textfileDir
    writeCollector
    collectorService
    collectorTimer
    ;

  cadenceOverrides = cfg.exporter.scrapeCadenceOverrides;
  overriddenHwmonRegex = lib.concatStringsSep "|" (
    lib.mapAttrsToList (_: override: "(${override.match})") cadenceOverrides
  );
  excludedHwmonRegex = lib.concatStringsSep "|" (
    lib.filter (regex: regex != "") [
      cfg.exporter.hwmonChipExclude
      overriddenHwmonRegex
    ]
  );

  sensorNameTable = pkgs.writeText "sensor-names" (
    lib.concatStringsSep "\n" (lib.mapAttrsToList (key: name: "${key}\t${name}") cfg.sensorNames)
  );

  sensorNames =
    writeCollector "sensor-names"
      [
        pkgs.gawk
        pkgs.gnused
      ]
      ''
        echo '# HELP node_sensor_name Friendly name for a hwmon sensor, keyed by chip name and sensor.'
        echo '# TYPE node_sensor_name gauge'
        for chip in /sys/class/hwmon/hwmon*; do
          chip_name=$(cat "$chip/name" 2>/dev/null) || continue
          for input in "$chip"/*_input; do
            [ -e "$input" ] || continue
            sensor=$(basename "$input" _input)
            name=$(sed -n "s|^$chip_name:$sensor\t||p" ${sensorNameTable} | head -1)
            if [ -z "$name" ] && [ -r "$chip/''${sensor}_label" ]; then
              name=$(cat "$chip/''${sensor}_label")
            fi
            [ -n "$name" ] || name="$chip_name $sensor"
            name=''${name//\\/}
            name=''${name//\"/}
            printf 'node_sensor_name{chip_name="%s",sensor="%s",name="%s"} 1\n' \
              "$chip_name" "$sensor" "$name"
          done
        done | sort -u

        # Several drives share the chip name "drivetemp", so they can only be told
        # apart by node_exporter's per-device chip label.
        echo '# HELP node_sensor_chip Friendly name for a hwmon sensor, keyed by chip and sensor.'
        echo '# TYPE node_sensor_chip gauge'
        echo '# HELP node_drive_bay Controller port a drive is attached to.'
        echo '# TYPE node_drive_bay gauge'
        for chip in /sys/class/hwmon/hwmon*; do
          [ "$(cat "$chip/name" 2>/dev/null)" = drivetemp ] || continue
          block=""
          for candidate in "$chip"/device/block/*; do
            [ -e "$candidate" ] || continue
            block=$(basename "$candidate")
            break
          done
          [ -n "$block" ] || continue
          device=$(readlink -f "$chip/device") || continue
          label=$(printf '%s' "$device" | awk -F/ '{ print $(NF-1) "_" $NF }')
          ata=$(readlink -f "/sys/block/$block" | grep -o 'ata[0-9]*' | head -1)
          bay=$(cat "/sys/class/ata_port/$ata/port_no" 2>/dev/null)
          [ -n "$bay" ] || continue
          for input in "$chip"/temp*_input; do
            [ -e "$input" ] || continue
            sensor=$(basename "$input" _input)
            printf 'node_sensor_chip{chip="%s",sensor="%s",name="HDD bay %s"} 1\n' \
              "$label" "$sensor" "$bay"
          done
          printf 'node_drive_bay{chip="%s",device="%s",bay="%s"} 1\n' \
            "$label" "$block" "$bay"
        done

        echo '# HELP pc_power_tariff_gbp_per_kwh Electricity price used for cost panels.'
        echo '# TYPE pc_power_tariff_gbp_per_kwh gauge'
        echo 'pc_power_tariff_gbp_per_kwh ${toString (cfg.totalPower.tariffPencePerKwh / 100.0)}'
        memory_kib=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
        memory_gib=$(( (memory_kib + 524288) / 1048576 ))
        echo '# HELP pc_memory_capacity_info Installed memory capacity group.'
        echo '# TYPE pc_memory_capacity_info gauge'
        printf 'pc_memory_capacity_info{capacity="%s GiB"} 1\n' "$memory_gib"
      '';

  power = cfg.power;

  diskProfileTable = pkgs.writeText "disk-power-profiles" (
    lib.concatMapStrings (
      profile:
      "${profile.match}\t${toString profile.standbyWatts}\t${toString profile.idleWatts}"
      + "\t${toString profile.activeWatts}\t${toString profile.spinUpWatts}\n"
    ) power.diskProfiles
  );

  diskOverrideTable = pkgs.writeText "disk-power-overrides" (
    lib.concatStrings (
      lib.mapAttrsToList (
        device: disk:
        "${device}\t${toString disk.standbyWatts}\t${toString disk.idleWatts}"
        + "\t${toString disk.activeWatts}\t${toString disk.spinUpWatts}\n"
      ) power.disks
    )
  );

  fanCoefficients = lib.concatStrings (
    lib.mapAttrsToList (
      name: fan:
      lib.optionalString (fan.constantWatts != 0) ''
        printf 'pc_power_fan_constant_watts{fan="%s"} %s\n' ${
          lib.escapeShellArgs [
            name
            (toString fan.constantWatts)
          ]
        }
      ''
      + lib.optionalString (fan.chip != "") (
        let
          labels = ''fan="${name}",chip_name="${fan.chip}",sensor="${fan.sensor}"'';
        in
        ''
          echo 'pc_power_fan_max_watts{${labels}} ${toString fan.wattsAtMaxRpm}'
          echo 'pc_power_fan_max_rpm{${labels}} ${toString fan.maxRpm}'
          echo 'pc_power_fan_exponent{${labels}} ${toString fan.exponent}'
        ''
      )
    ) power.fans
  );

  drivePowerState = ''
    drive_power_state() {
      local device=$1 mode report
      report=$(hdparm -C "/dev/$device" 2>/dev/null || true)
      if printf '%s' "$report" | grep -q 'active/idle'; then
        printf active
        return
      fi
      if printf '%s' "$report" | grep -q 'standby'; then
        printf standby
        return
      fi

      mode=$(cat "/var/lib/smart-health/$device.mode" 2>/dev/null || echo auto)
      if [ "$mode" = sat ]; then
        report=$(smartctl -n standby -j -d sat -i "/dev/$device" 2>/dev/null || true)
      else
        report=$(smartctl -n standby -j -i "/dev/$device" 2>/dev/null || true)
      fi
      if printf '%s' "$report" | jq -e '[.smartctl.messages[]?.string] | any(test("STANDBY"))' >/dev/null 2>&1; then
        printf standby
      elif printf '%s' "$report" | jq -e '.model_name' >/dev/null 2>&1; then
        printf active
      else
        printf unknown
      fi
    }
  '';

  powerModel =
    writeCollector "power-model"
      [
        pkgs.gawk
        pkgs.hdparm
        pkgs.jq
        pkgs.smartmontools
      ]
      ''
        echo '# HELP pc_power_supply_rated_watts Nameplate output of the supply.'
        echo '# TYPE pc_power_supply_rated_watts gauge'
        echo 'pc_power_supply_rated_watts ${toString power.supply.ratedWatts}'
        echo 'pc_power_supply_peak_efficiency ${toString power.supply.peakEfficiency}'
        echo 'pc_power_supply_peak_load_ratio ${toString power.supply.peakLoadRatio}'
        echo 'pc_power_supply_curvature ${toString power.supply.curvature}'
        echo 'pc_power_supply_idle_watts ${toString power.supply.idleWatts}'
        echo 'pc_power_board_watts ${toString power.boardWatts}'
        echo 'pc_power_peripherals_watts ${toString power.peripheralsWatts}'
        echo 'pc_power_gpu_board_factor ${toString power.gpu.boardFactor}'
        echo 'pc_power_gpu_overhead_watts ${toString power.gpu.overheadWatts}'
        echo 'pc_power_pmic_efficiency ${toString power.pmicEfficiency}'

        ${fanCoefficients}

        ${lib.optionalString power.ram.modelled ''
          memory_gib=$(awk '/^MemTotal:/ { printf "%.4f", $2 / 1048576 }' /proc/meminfo)
          echo '# HELP pc_power_ram_watts Modelled DRAM draw at rest and at full load.'
          echo '# TYPE pc_power_ram_watts gauge'
          awk -v gib="$memory_gib" 'BEGIN {
            printf "pc_power_ram_watts{state=\"idle\"} %.4f\n", gib * ${toString power.ram.wattsPerGiB}
            printf "pc_power_ram_watts{state=\"active\"} %.4f\n", gib * ${toString power.ram.activeWattsPerGiB}
          }'
        ''}

        ${lib.optionalString (power.backlightMaxWatts != 0) ''
          echo 'pc_power_backlight_max_watts ${toString power.backlightMaxWatts}'
          for panel in /sys/class/backlight/*; do
            [ -r "$panel/actual_brightness" ] || continue
            now=$(cat "$panel/actual_brightness")
            full=$(cat "$panel/max_brightness")
            [ "$full" -gt 0 ] || continue
            awk -v now="$now" -v full="$full" -v panel="''${panel##*/}" 'BEGIN {
              printf "pc_backlight_ratio{panel=\"%s\"} %.4f\n", panel, now / full
            }'
          done
        ''}

        echo '# HELP pc_power_disk_watts Modelled draw of a drive in each power state.'
        echo '# TYPE pc_power_disk_watts gauge'
        echo '# HELP pc_disk_standby Whether the drive motor is stopped.'
        echo '# TYPE pc_disk_standby gauge'

        profile_for() {
          local model=$1 class=$2 match standby idle active spinup
          while IFS=$'\t' read -r match standby idle active spinup; do
            case "$match" in
              @*) [ "$match" = "$class" ] || continue ;;
              *) case "$model" in *"$match"*) ;; *) continue ;; esac ;;
            esac
            printf '%s\t%s\t%s\t%s\n' "$standby" "$idle" "$active" "$spinup"
            return 0
          done < ${diskProfileTable}
          return 1
        }

        ${drivePowerState}

        for block in /sys/block/*; do
          device=''${block##*/}
          case "$device" in
            loop* | ram* | zram* | dm-* | md* | sr*) continue ;;
          esac
          [ -e "$block/device" ] || continue

          rotational=$(cat "$block/queue/rotational" 2>/dev/null || echo 0)
          if [ "$rotational" = 1 ]; then
            class=@rotational
          elif [ "''${device#nvme}" != "$device" ]; then
            class=@nvme
          else
            class=@ssd
          fi

          model=$(cat "$block/device/model" 2>/dev/null || true)
          coefficients=$(profile_for "$model" "$class") || continue
          override=$(awk -F'\t' -v d="$device" '$1 == d {
            print $2 "\t" $3 "\t" $4 "\t" $5
          }' ${diskOverrideTable})
          [ -z "$override" ] || coefficients=$override

          IFS=$'\t' read -r standby idle active spinup <<<"$coefficients"
          printf 'pc_power_disk_watts{device="%s",state="standby"} %s\n' "$device" "$standby"
          printf 'pc_power_disk_watts{device="%s",state="idle"} %s\n' "$device" "$idle"
          printf 'pc_power_disk_watts{device="%s",state="active"} %s\n' "$device" "$active"
          printf 'pc_power_disk_watts{device="%s",state="spinup"} %s\n' "$device" "$spinup"

          case $(drive_power_state "$device") in
            active) printf 'pc_disk_standby{device="%s"} 0\n' "$device" ;;
            standby) printf 'pc_disk_standby{device="%s"} 1\n' "$device" ;;
          esac
        done
      '';

  piFirmwareMetrics =
    writeCollector "pi-firmware"
      [
        pkgs.raspberrypi-utils
        pkgs.gawk
      ]
      ''
        echo '# TYPE pi_pmic_current_amps gauge'
        echo '# TYPE pi_pmic_voltage_volts gauge'
        vcgencmd pmic_read_adc | awk '
          match($0, /^[[:space:]]*([^[:space:]]+)[[:space:]]+(current|volt)\([0-9]+\)=([0-9.]+)(A|V)$/, fields) {
            rail = fields[1]
            sub(/_[AV]$/, "", rail)
            if (fields[2] == "current")
              printf "pi_pmic_current_amps{rail=\"%s\"} %s\n", rail, fields[3]
            else
              printf "pi_pmic_voltage_volts{rail=\"%s\"} %s\n", rail, fields[3]
          }
        '
        flags=$(vcgencmd get_throttled 2>/dev/null | sed -n 's/.*0x//p')
        [ -n "$flags" ] || flags=0
        value=$((16#$flags))
        for entry in under_voltage:0 frequency_capped:1 throttled:2 soft_temp_limit:3 under_voltage_since_boot:16 frequency_capped_since_boot:17 throttled_since_boot:18 soft_temp_limit_since_boot:19; do
          name=''${entry%%:*}
          bit=''${entry##*:}
          printf 'pi_firmware_flag{flag="%s"} %s\n' "$name" "$(( (value >> bit) & 1 ))"
        done
      '';

  laptopBatteryMetrics = writeCollector "laptop-battery" [ pkgs.gawk ] ''
    echo '# TYPE laptop_battery_energy_watt_hours gauge'
    echo '# TYPE laptop_battery_power_watts gauge'
    echo '# TYPE laptop_battery_health_ratio gauge'
    for battery in /sys/class/power_supply/BAT*; do
      [ -d "$battery" ] || continue
      name=$(basename "$battery")
      read_value() { cat "$battery/$1" 2>/dev/null || echo 0; }
      energy_now=$(read_value energy_now)
      energy_full=$(read_value energy_full)
      energy_design=$(read_value energy_full_design)
      power_now=$(read_value power_now)
      voltage_now=$(read_value voltage_now)
      current_now=$(read_value current_now)
      capacity=$(read_value capacity)
      cycles=$(read_value cycle_count)
      status=$(read_value status | tr -cd '[:alnum:]_-')
      [ "$power_now" -gt 0 ] 2>/dev/null || power_now=$(( voltage_now * current_now / 1000000 ))
      awk -v name="$name" -v now="$energy_now" -v full="$energy_full" -v design="$energy_design" -v power="$power_now" -v capacity="$capacity" -v cycles="$cycles" -v status="$status" '
        BEGIN {
          printf "laptop_battery_energy_watt_hours{battery=\"%s\",kind=\"current\"} %.6f\n", name, now / 1000000
          printf "laptop_battery_energy_watt_hours{battery=\"%s\",kind=\"full\"} %.6f\n", name, full / 1000000
          printf "laptop_battery_energy_watt_hours{battery=\"%s\",kind=\"design\"} %.6f\n", name, design / 1000000
          printf "laptop_battery_power_watts{battery=\"%s\"} %.6f\n", name, power / 1000000
          if (design > 0) printf "laptop_battery_health_ratio{battery=\"%s\"} %.6f\n", name, full / design
          printf "laptop_battery_capacity_ratio{battery=\"%s\"} %.6f\n", name, capacity / 100
          printf "laptop_battery_cycles{battery=\"%s\"} %s\n", name, cycles
          printf "laptop_battery_status_info{battery=\"%s\",status=\"%s\"} 1\n", name, status
        }
      '
    done
  '';

  tailscaleMetrics =
    writeCollector "tailscale"
      [
        pkgs.tailscale
        pkgs.jq
      ]
      ''
        status=$(tailscale status --json) || exit 0

        echo '# HELP tailscale_peer_rx_bytes_total Bytes received from a peer this session.'
        echo '# TYPE tailscale_peer_rx_bytes_total counter'
        echo '# HELP tailscale_peer_tx_bytes_total Bytes sent to a peer this session.'
        echo '# TYPE tailscale_peer_tx_bytes_total counter'
        echo '# HELP tailscale_peer_online Whether the coordination server reports the peer as up.'
        echo '# TYPE tailscale_peer_online gauge'
        echo '# HELP tailscale_peer_direct Whether traffic to the peer avoids a DERP relay.'
        echo '# TYPE tailscale_peer_direct gauge'
        echo '# HELP tailscale_peer_last_handshake_seconds Unix time of the last wireguard handshake.'
        echo '# TYPE tailscale_peer_last_handshake_seconds gauge'

        jq -r '.Peer[] | [.HostName, .OS, .Relay, (.Online|tostring),
                          (if .CurAddr == "" then "0" else "1" end),
                          (.RxBytes|tostring), (.TxBytes|tostring),
                          (.LastHandshake // "")] | @tsv' <<<"$status" \
        | while IFS=$'\t' read -r peer os relay online direct rx tx handshake; do
            labels="peer=\"$peer\",peer_os=\"$os\",relay=\"$relay\""
            printf 'tailscale_peer_rx_bytes_total{%s} %s\n' "$labels" "$rx"
            printf 'tailscale_peer_tx_bytes_total{%s} %s\n' "$labels" "$tx"
            printf 'tailscale_peer_online{%s} %s\n' "$labels" "$([ "$online" = true ] && echo 1 || echo 0)"
            printf 'tailscale_peer_direct{%s} %s\n' "$labels" "$direct"
            epoch=0
            case "$handshake" in
              ""|0001-01-01*) ;;
              *) epoch=$(date -d "$handshake" +%s 2>/dev/null || echo 0) ;;
            esac
            printf 'tailscale_peer_last_handshake_seconds{%s} %s\n' "$labels" "$epoch"
          done

        tailscale metrics print 2>/dev/null || true
      '';

  wireguardMetrics =
    writeCollector "wireguard"
      [
        pkgs.wireguard-tools
        pkgs.gawk
      ]
      ''
        echo '# HELP wireguard_peer_latest_handshake_seconds Unix time of the last handshake.'
        echo '# TYPE wireguard_peer_latest_handshake_seconds gauge'
        echo '# HELP wireguard_peer_rx_bytes_total Bytes received from the peer.'
        echo '# TYPE wireguard_peer_rx_bytes_total counter'
        echo '# HELP wireguard_peer_tx_bytes_total Bytes sent to the peer.'
        echo '# TYPE wireguard_peer_tx_bytes_total counter'

        wg show all dump 2>/dev/null | awk -F'\t' 'NF >= 9 {
          split($4, endpoint, ":")
          labels = "interface=\"" $1 "\",endpoint=\"" endpoint[1] "\""
          printf "wireguard_peer_latest_handshake_seconds{%s} %s\n", labels, $6
          printf "wireguard_peer_rx_bytes_total{%s} %s\n", labels, $7
          printf "wireguard_peer_tx_bytes_total{%s} %s\n", labels, $8
        }'
      '';

  nixBuildMetrics =
    writeCollector "nix-builds"
      [
        pkgs.systemd
        pkgs.jq
      ]
      ''
        echo '# HELP nix_events_24h Nix invocations recorded in this host'"'"'s journal over the last 24 hours.'
        echo '# TYPE nix_events_24h gauge'
        echo '# HELP nix_alertable_failures_24h Failures the observer marked alert-eligible.'
        echo '# TYPE nix_alertable_failures_24h gauge'
        echo '# HELP nix_last_seconds Unix time of the most recent invocation of this event and status.'
        echo '# TYPE nix_last_seconds gauge'
        echo '# HELP nix_last_duration_seconds Duration of the most recent invocation of this event and status.'
        echo '# TYPE nix_last_duration_seconds gauge'

        journalctl -t nix-observer-summary --since -24h -o json --no-pager 2>/dev/null \
          | jq -rs '
              map(
                . as $entry
                | ($entry.MESSAGE | fromjson? // empty)
                | select(.event != null)
                | . + { ts: (($entry.__REALTIME_TIMESTAMP // "0") | tonumber / 1000000) }
              )
              | group_by([.event, .status])
              | map({
                  event: .[0].event,
                  status: .[0].status,
                  count: length,
                  alertable: (map(select(.alert_eligible == true)) | length),
                  last: max_by(.ts),
                })
              | .[]
              | "nix_events_24h{event=\"\(.event)\",status=\"\(.status)\"} \(.count)",
                "nix_alertable_failures_24h{event=\"\(.event)\",status=\"\(.status)\"} \(.alertable)",
                "nix_last_seconds{event=\"\(.event)\",status=\"\(.status)\"} \(.last.ts)",
                "nix_last_duration_seconds{event=\"\(.event)\",status=\"\(.status)\"} \(.last.duration_seconds // 0)"
            '
      '';

  memoryByUnit = writeCollector "memory-by-unit" [ pkgs.findutils ] ''
    echo '# HELP node_unit_memory_bytes Memory currently charged to a systemd unit cgroup.'
    echo '# TYPE node_unit_memory_bytes gauge'
    echo '# HELP node_unit_memory_peak_bytes Peak memory charged to a systemd unit cgroup.'
    echo '# TYPE node_unit_memory_peak_bytes gauge'

    emit() {
      local unit=$1 dir=$2 current peak
      [ -r "$dir/memory.current" ] || return 0
      read -r current < "$dir/memory.current" || return 0
      [ "$current" -gt 0 ] || return 0
      printf 'node_unit_memory_bytes{unit="%s"} %s\n' "$unit" "$current"
      if [ -r "$dir/memory.peak" ] && read -r peak < "$dir/memory.peak"; then
        printf 'node_unit_memory_peak_bytes{unit="%s"} %s\n' "$unit" "$peak"
      fi
    }

    while IFS= read -r dir; do
      emit "''${dir##*/}" "$dir"
    done < <(find /sys/fs/cgroup/system.slice -mindepth 1 -type d -name '*.service' 2>/dev/null)

    emit user.slice /sys/fs/cgroup/user.slice
  '';

  # Kernel uptime counts time spent suspended, so boot time cannot answer
  # "how long has this host been awake".
  awakeSince = writeCollector "awake-since" [ pkgs.gawk ] ''
    if [ "''${1:-}" = resume ]; then
      since=$(date +%s)
    else
      since=$(awk '/^btime/ { print $2 }' /proc/stat)
      previous=$(awk '/^node_awake_since_seconds/ { print $2 }' "$out" 2>/dev/null || true)
      if [ -n "$previous" ] && [ "$previous" -gt "$since" ]; then
        since=$previous
      fi
    fi
    echo '# HELP node_awake_since_seconds Unix time of the last boot or resume.'
    echo '# TYPE node_awake_since_seconds gauge'
    printf 'node_awake_since_seconds %s\n' "$since"
  '';

  hwmonOverrideCollector =
    name: override:
    writeCollector "hwmon-${name}"
      [
        pkgs.gawk
        pkgs.gnugrep
        pkgs.hdparm
        pkgs.jq
        pkgs.smartmontools
      ]
      ''
        echo '# HELP node_hwmon_temp_celsius Hardware monitor for temperature (input)'
        echo '# TYPE node_hwmon_temp_celsius gauge'
        echo '# HELP node_hwmon_chip_names Annotation metric for human-readable chip names'
        echo '# TYPE node_hwmon_chip_names gauge'
        ${drivePowerState}
        for chip in /sys/class/hwmon/hwmon*; do
          chip_name=$(cat "$chip/name" 2>/dev/null) || continue
          device=$(readlink -f "$chip/device") || continue
          label=$(printf '%s' "$device" | awk -F/ '{ print $(NF-1) "_" $NF }')
          printf '%s\n' "$label" | grep -Eq -- ${lib.escapeShellArg override.match} || continue

          ${lib.optionalString override.onlyWhenActive ''
            block=""
            for candidate in "$chip"/device/block/*; do
              [ -e "$candidate" ] || continue
              block=$(basename "$candidate")
              break
            done
            [ -n "$block" ] || continue
            [ "$(drive_power_state "$block")" = active ] || continue
          ''}

          printf 'node_hwmon_chip_names{chip="%s",chip_name="%s"} 1\n' "$label" "$chip_name"
          for input in "$chip"/temp*_input; do
            [ -e "$input" ] || continue
            sensor=$(basename "$input" _input)
            read -r milli < "$input" || continue
            printf '%s\n' "$milli" | grep -Eq '^-?[0-9]+$' || continue
            printf 'node_hwmon_temp_celsius{chip="%s",sensor="%s"} %s\n' \
              "$label" "$sensor" "$(awk -v m="$milli" 'BEGIN { printf "%.3f", m / 1000 }')"
          done
        done
      '';

  cadenceOverrideServices = lib.mapAttrs' (
    name: override:
    lib.nameValuePair "textfile-hwmon-${name}" (
      lib.mkMerge [
        (collectorService (hwmonOverrideCollector name override))
        {
          description = "Publish ${name} hwmon metrics at an overridden cadence";
          wantedBy = [ "multi-user.target" ];
          after = [ "systemd-modules-load.service" ];
        }
      ]
    )
  ) cadenceOverrides;

  cadenceOverrideTimers = lib.mapAttrs' (
    name: override: lib.nameValuePair "textfile-hwmon-${name}" (collectorTimer override.interval)
  ) cadenceOverrides;

  hasWireguard = config.networking.wg-quick.interfaces != { };
in

{
  config = lib.mkIf cfg.exporter.enable (
    lib.mkMerge [
      {
        systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];

        services.prometheus.exporters.node.extraFlags = [
          "--collector.textfile.directory=${textfileDir}"
          "--collector.vmstat.fields=^(oom_kill|pgpg|pswp|pg.*fault|workingset_.*|pgscan.*|pgsteal.*).*"
        ]
        ++ lib.optional (excludedHwmonRegex != "") "--collector.hwmon.chip-exclude=${excludedHwmonRegex}";

        systemd.services.textfile-awake-since = lib.mkMerge [
          (collectorService awakeSince)
          {
            description = "Publish the last boot or resume time";
            wantedBy = [ "multi-user.target" ];
          }
        ];

        environment.etc."systemd/system-sleep/textfile-awake-since" = {
          mode = "0755";
          source = pkgs.writeShellScript "textfile-awake-since-sleep" ''
            if [ "$1" = post ]; then
              ${lib.getExe awakeSince} resume
            fi
            exit 0
          '';
        };

        systemd.services.textfile-sensor-names = lib.mkMerge [
          (collectorService sensorNames)
          {
            description = "Publish friendly hwmon sensor names";
            wantedBy = [ "multi-user.target" ];
            after = [ "systemd-modules-load.service" ];
            restartTriggers = [ sensorNameTable ];
          }
        ];

        systemd.services.textfile-power-model = lib.mkIf power.enable (
          lib.mkMerge [
            (collectorService powerModel)
            {
              description = "Publish power model coefficients and drive standby state";
              wantedBy = [ "multi-user.target" ];
              restartTriggers = [
                diskProfileTable
                diskOverrideTable
              ];
            }
          ]
        );

        systemd.timers.textfile-power-model = lib.mkIf power.enable (collectorTimer "5s");

        systemd.services.textfile-tailscale = lib.mkIf config.services.tailscale.enable (
          lib.mkMerge [
            (collectorService tailscaleMetrics)
            { description = "Publish per-peer tailnet traffic and reachability"; }
          ]
        );

        systemd.timers.textfile-tailscale = lib.mkIf config.services.tailscale.enable (
          collectorTimer "15s"
        );

        systemd.services.textfile-wireguard = lib.mkIf hasWireguard (
          lib.mkMerge [
            (collectorService wireguardMetrics)
            { description = "Publish wireguard handshake age and byte counters"; }
          ]
        );

        systemd.timers.textfile-wireguard = lib.mkIf hasWireguard (collectorTimer "30s");

        systemd.services.textfile-pi-firmware = lib.mkIf cfg.piFirmware.enable (
          lib.mkMerge [
            (collectorService piFirmwareMetrics)
            { description = "Publish Raspberry Pi firmware and PMIC telemetry"; }
          ]
        );

        systemd.timers.textfile-pi-firmware = lib.mkIf cfg.piFirmware.enable (collectorTimer "1s");

        systemd.services.textfile-laptop-battery = lib.mkIf cfg.laptopTelemetry.enable (
          lib.mkMerge [
            (collectorService laptopBatteryMetrics)
            { description = "Publish laptop battery telemetry"; }
          ]
        );

        systemd.timers.textfile-laptop-battery = lib.mkIf cfg.laptopTelemetry.enable (collectorTimer "5s");

        systemd.services.textfile-memory-by-unit = lib.mkMerge [
          (collectorService memoryByUnit)
          { description = "Publish per-unit memory from the systemd cgroup hierarchy"; }
        ];

        systemd.timers.textfile-memory-by-unit = collectorTimer "15s";

        systemd.services.textfile-nix-builds = lib.mkMerge [
          (collectorService nixBuildMetrics)
          { description = "Publish Nix build outcomes from the local journal"; }
        ];

        systemd.timers.textfile-nix-builds = collectorTimer "60s";
      }
      {
        systemd.services = cadenceOverrideServices;
        systemd.timers = cadenceOverrideTimers;
      }
    ]
  );
}

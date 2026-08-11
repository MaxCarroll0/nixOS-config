# Idle power policy and power measurement.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.power;

  powerReport = pkgs.writeShellApplication {
    name = "power-report";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.bc
      pkgs.curl
      pkgs.jq
      pkgs.gnuplot
    ];
    text = ''
      interval="''${1:-5}"
      history="''${2:-24 hours}"
      declare -A before
      available=0
      domains=0
      for d in /sys/class/powercap/*/; do
        [ -e "$d/energy_uj" ] || continue
        available=$((available + 1))
        [ -r "$d/energy_uj" ] || continue
        before["$d"]=$(cat "$d/energy_uj")
        domains=$((domains + 1))
      done
      if [ "$domains" -eq 0 ]; then
        if [ "$available" -eq 0 ]; then
          echo "no powercap energy counters found." >&2
        else
          echo "no readable powercap domains." >&2
          echo "energy_uj is root-only since Linux 5.10; set" >&2
          echo "local.monitoring.userReadable = true, or run this as root." >&2
        fi
        exit 1
      fi
      sleep "$interval"
      for d in /sys/class/powercap/*/; do
        [ -r "$d/energy_uj" ] || continue
        name=$(cat "$d/name" 2>/dev/null || basename "$d")
        after=$(cat "$d/energy_uj")
        delta=$(( after - ''${before["$d"]} ))
        # The counter wraps at max_energy_range_uj.
        if [ "$delta" -lt 0 ]; then
          range=$(cat "$d/max_energy_range_uj" 2>/dev/null || echo 0)
          [ "$range" -gt 0 ] || continue
          delta=$(( delta + range ))
        fi
        printf '%-24s %6.2f W\n' "$name" "$(echo "scale=2; $delta / 1000000 / $interval" | bc)"
      done

      start=$(date --date="$history ago" +%s)
      end=$(date +%s)
      reports=$(mktemp --directory)
      trap 'rm -rf "$reports"' EXIT

      graph() {
        key="$1"
        title="$2"
        query="$3"
        report="$reports/$key"

        if ! curl --fail --silent --show-error --get \
          --data-urlencode "query=$query" \
          --data-urlencode "start=$start" \
          --data-urlencode "end=$end" \
          --data-urlencode "step=60" \
          http://127.0.0.1:9091/api/v1/query_range \
          | jq -r '.data.result[0].values[]? | "\(.[0]) \(.[1])"' > "$report"; then
          echo "could not read historical $title data" >&2
          return
        fi

        if [ ! -s "$report" ]; then
          echo "no historical $title data yet" >&2
          return
        fi

        printf '\n%s, last %s\n' "$title" "$history"
        gnuplot <<EOF
      set terminal dumb 100 20
      set xdata time
      set timefmt "%s"
      set format x "%H:%M"
      set ylabel "W"
      set yrange [0:*]
      plot "$report" using 1:2 with lines title "$title"
      EOF
      }

      graph total "Total" "avg1m:pc_power_watts"
      graph cpu "CPU" "avg1m:pc_cpu_power_watts"
      graph gpu "GPU" "avg1m:pc_gpu_power_watts"
    '';
  };

  powerStats = pkgs.writeShellApplication {
    name = "power-stats";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      metric_query() {
        case "$1" in
          total) echo 'avg1m:pc_power_watts' ;;
          cpu) echo 'avg1m:pc_cpu_power_watts' ;;
          gpu) echo 'avg1m:pc_gpu_power_watts' ;;
        esac
      }

      stat() {
        agg="$1"
        query="$2"
        range="$3"
        curl --fail --silent --show-error --get \
          --data-urlencode "query=''${agg}_over_time((''${query})[''${range}:1m])" \
          http://127.0.0.1:9091/api/v1/query \
          | jq -r '(.data.result[0].value[1] // "n/a") as $v
                   | if $v == "n/a" then $v else ($v | tonumber | (. * 100 | round) / 100 | tostring) end'
      }

      printf '%-12s %-6s %8s %8s %8s\n' metric range min avg max
      for key in total cpu gpu; do
        query=$(metric_query "$key")
        for range in 24h 7d 30d; do
          min=$(stat min "$query" "$range")
          avg=$(stat avg "$query" "$range")
          max=$(stat max "$query" "$range")
          printf '%-12s %-6s %8s %8s %8s\n' "$key" "$range" "$min" "$avg" "$max"
        done
      done
    '';
  };

  powertopSnapshot = pkgs.writeShellApplication {
    name = "powertop-snapshot";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.powertop
    ];
    text = ''
      exec powertop --quiet --csv="/var/log/powertop/$(date --utc +%Y%m%dT%H%M%SZ).csv" --time=10
    '';
  };

  softPowerCommand =
    name: service: dpms:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.kdePackages.libkscreen
        pkgs.systemd
        pkgs.util-linux
      ];
      text = ''
        if [ "$(id -u)" -ne 0 ]; then
          echo "run with sudo" >&2
          exit 1
        fi

        ${pkgs.systemd}/bin/systemctl start ${service}.service

        session_uid="''${SUDO_UID:-1000}"
        session_user="''${SUDO_USER:-max}"
        runtime_dir="/run/user/$session_uid"
        wayland_display=""
        for socket in "$runtime_dir"/wayland-*; do
          if [ -S "$socket" ]; then
            wayland_display=$(basename "$socket")
            break
          fi
        done
        if [ -n "$wayland_display" ]; then
          runuser -u "$session_user" -- env \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
            WAYLAND_DISPLAY="$wayland_display" \
            kscreen-doctor --dpms ${dpms}
        fi
      '';
    };
  peripherals = pkgs.writeShellScript "usb-peripherals" ''
    for device in /sys/bus/usb/devices/*; do
      [ -w "$device/power/control" ] || continue
      [ "$(cat "$device/bDeviceClass" 2>/dev/null || true)" = "09" ] && continue
      [ -d "$device/net" ] && continue
      echo "$device"
    done
    exit 0
  '';

  suspendSoft = softPowerCommand "suspend-soft" "suspend-soft-hardware" "off";
  wakeSoft = softPowerCommand "wake-soft" "wake-soft-hardware" "on";
  sessionActivity = pkgs.writeShellApplication {
    name = "session-activity";
    runtimeInputs = with pkgs; [
      coreutils
      procps
      systemd
    ];
    text = ''
      resident=$(systemctl show -p MainPID --value nix-daemon.service 2>/dev/null || echo 0)
      for pid in $(pgrep -x nix-daemon || true); do
        if [ "$pid" != "$resident" ]; then
          exit 0
        fi
      done

      if [ "$resident" != 0 ] && pgrep -P "$resident" >/dev/null 2>&1; then
        exit 0
      fi

      threshold=$(( $(date +%s) - ${toString (cfg.idle.autosuspend.idleMinutes * 60)} ))
      for pty in /dev/pts/*; do
        [ -c "$pty" ] || continue
        case "$pty" in
          */ptmx) continue ;;
        esac
        atime=$(stat -c %X "$pty" 2>/dev/null || echo 0)
        if [ "$atime" -gt "$threshold" ]; then
          exit 0
        fi
      done

      exit 1
    '';
  };

  suspendThenPowerOff =
    hours:
    pkgs.writeShellApplication {
      name = "suspend-then-power-off";
      runtimeInputs = with pkgs; [
        coreutils
        gawk
        systemd
      ];
      text = ''
        alarm=/sys/class/rtc/rtc0/wakealarm
        target=$(( $(date +%s) + ${toString (hours * 3600)} ))

        # Writing a wakealarm that is already armed fails EBUSY.
        echo 0 > "$alarm"
        echo "$target" > "$alarm"

        systemctl suspend

        if [ "$(date +%s)" -lt "$(( target - 60 ))" ]; then
          echo 0 > "$alarm"
          exit 0
        fi

        sleep 60
        echo 0 > "$alarm"

        for session in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
          seat=$(loginctl show-session "$session" -p Seat --value 2>/dev/null || true)
          class=$(loginctl show-session "$session" -p Class --value 2>/dev/null || true)
          if [ -n "$seat" ] && [ "$class" = user ]; then
            exec systemctl suspend
          fi
        done

        if ${lib.getExe sessionActivity}; then
          exit 0
        fi

        exec systemctl poweroff
      '';
    };
in

{
  options.local.power = {
    instrument = lib.mkEnableOption "below, powertop snapshots and the power CLI tools";

    idle.optimise = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Cut idle draw without suspending. Applies under every policy.";
    };

    idle.policy = lib.mkOption {
      type = lib.types.enum [
        "always-on"
        "scheduled"
        "autosuspend"
      ];
      default = "always-on";
      description = ''
        always-on   never suspends; anything hosted here stays reachable
        scheduled   suspends between sleepAt and wakeAt, RTC wakeup
        autosuspend suspends whenever idle checks all report inactive
      '';
    };

    idle.scheduled.sleepAt = lib.mkOption {
      type = lib.types.str;
      default = "01:00";
    };

    idle.scheduled.wakeAt = lib.mkOption {
      type = lib.types.str;
      default = "08:00";
    };

    idle.autosuspend.idleMinutes = lib.mkOption {
      type = lib.types.int;
      default = 20;
    };

    idle.autosuspend.loadThreshold = lib.mkOption {
      type = lib.types.float;
      default = 2.5;
      description = "Load average above which the host counts as busy.";
    };

    idle.autosuspend.watchPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 22 ];
      description = "An established connection to any of these counts as activity.";
    };

    idle.autosuspend.powerOffAfterHours = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Escalate from suspend to power off after this long still idle.";
    };

    wakeOnLan.interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    wakeOnLan.mac = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Recorded here for the client side; Nix cannot set the BIOS.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = (cfg.wakeOnLan.interface == null) == (cfg.wakeOnLan.mac == null);
          message = "local.power.wakeOnLan needs both interface and mac, or neither.";
        }
      ];

      warnings = lib.optional (
        cfg.idle.policy != "always-on" && cfg.wakeOnLan.mac == null
      ) "idle.policy \"${cfg.idle.policy}\" with no Wake-on-LAN, so nothing can wake this host remotely.";

      environment.systemPackages = [
        powerReport
        powerStats
      ]
      ++ (with pkgs; [
        below
        btop
        powertop
        powerstat
        s-tui
        lm_sensors
        wtfutil
      ])
      ++ lib.optionals cfg.idle.optimise [
        suspendSoft
        wakeSoft
        pkgs.nvtopPackages.amd
      ];

    }

    (lib.mkIf (cfg.wakeOnLan.interface != null) {
      networking.interfaces.${cfg.wakeOnLan.interface}.wakeOnLan.enable = true;

      environment.systemPackages = [ pkgs.ethtool ];

      networking.networkmanager.ensureProfiles.profiles.${cfg.wakeOnLan.interface} = {
        connection = {
          id = cfg.wakeOnLan.interface;
          type = "802-3-ethernet";
          interface-name = cfg.wakeOnLan.interface;
          autoconnect = true;
        };
        # NM_SETTING_WIRED_WAKE_ON_LAN_MAGIC. The keyfile parser rejects the
        # name "magic" here: it only accepts the numeric flag.
        "802-3-ethernet".wake-on-lan = 64;
        ipv4.method = "auto";
        ipv6.method = "auto";
      };

      networking.networkmanager.dispatcherScripts = [
        {
          type = "basic";
          source = pkgs.writeShellScript "arm-wake-on-lan" ''
            [ "$1" = "${cfg.wakeOnLan.interface}" ] || exit 0
            case "$2" in
              up|dhcp4-change) ${pkgs.ethtool}/bin/ethtool -s "$1" wol g || true ;;
            esac
          '';
        }
      ];

      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="net", NAME=="${cfg.wakeOnLan.interface}", RUN+="${pkgs.ethtool}/bin/ethtool -s ${cfg.wakeOnLan.interface} wol g"
        ACTION=="add", SUBSYSTEM=="net", NAME=="${cfg.wakeOnLan.interface}", RUN+="${pkgs.iproute2}/bin/ip link set ${cfg.wakeOnLan.interface} up"
        ACTION=="add|change", SUBSYSTEM=="pci", DRIVERS=="r8169", ATTR{power/wakeup}="enabled"
      '';

      # r8169 clears the WoL bit during shutdown, so S5 wake needs it re-armed
      # after the network stack is gone but before power is cut.
      systemd.services.wake-on-lan-shutdown = {
        description = "Re-arm Wake-on-LAN across shutdown";
        wantedBy = [ "shutdown.target" ];
        before = [ "shutdown.target" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
          ExecStop = "${pkgs.ethtool}/bin/ethtool -s ${cfg.wakeOnLan.interface} wol g";
        };
      };
    })

    (lib.mkIf cfg.idle.optimise {
      boot.kernelParams = [ "amd_pstate=guided" ];
      powerManagement.enable = true;
      powerManagement.cpuFreqGovernor = "schedutil";
      powerManagement.powertop.enable = true;

      hardware.bluetooth.powerOnBoot = false;

      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="scsi_host", KERNEL=="host*", ATTR{link_power_management_policy}="med_power_with_dipm"
        ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="258a", ATTR{idProduct}=="1006", TEST=="power/control", ATTR{power/autosuspend_delay_ms}="300000", ATTR{power/control}="auto"
        ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="1d57", ATTR{idProduct}=="ad17", TEST=="power/control", ATTR{power/autosuspend_delay_ms}="300000", ATTR{power/control}="auto"
      '';

      systemd.services.input-autosuspend = {
        description = "Delay USB input autosuspend";
        after = [ "powertop.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig.Type = "oneshot";
        script = ''
          for device in /sys/bus/usb/devices/*; do
            id="$(cat "$device/idVendor" 2>/dev/null || true):$(cat "$device/idProduct" 2>/dev/null || true)"
            if [ "$id" = 258a:1006 ] || [ "$id" = 1d57:ad17 ]; then
              echo 300000 > "$device/power/autosuspend_delay_ms"
              echo auto > "$device/power/control"
            fi
          done
        '';
      };

      systemd.services.suspend-soft-hardware = {
        description = "Park peripherals without suspending the system";
        serviceConfig.Type = "oneshot";
        script = ''
          ${peripherals} | while read -r device; do
            echo 0 > "$device/power/autosuspend_delay_ms"
            echo auto > "$device/power/control"
          done

          sleep 3

          ${peripherals} | while read -r device; do
            echo 300000 > "$device/power/autosuspend_delay_ms"
          done

          for device in /sys/block/*; do
            if [ "$(cat "$device/queue/rotational" 2>/dev/null || true)" = 1 ]; then
              ${pkgs.hdparm}/bin/hdparm -y "/dev/$(basename "$device")"
            fi
          done
        '';
      };
      systemd.services.wake-soft-hardware = {
        description = "Restore peripheral power without changing the system power state";
        serviceConfig.Type = "oneshot";
        script = ''
          ${peripherals} | while read -r device; do
            echo on > "$device/power/control"
            echo 300000 > "$device/power/autosuspend_delay_ms"
            echo auto > "$device/power/control"
          done
        '';
      };

      powerManagement.powerDownCommands = ''
        ${pkgs.systemd}/bin/systemctl start suspend-soft-hardware.service
      '';
    })

    (lib.mkIf (cfg.idle.policy == "always-on") {
      boot.kernelParams = [
        "panic=10"
        "oops=panic"
      ];

      systemd.settings.Manager = {
        RuntimeWatchdogSec = "60s";
        RebootWatchdogSec = "3min";
      };

      systemd.enableEmergencyMode = false;
    })

    (lib.mkIf (cfg.idle.policy == "scheduled") {
      systemd.timers.scheduled-suspend = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.idle.scheduled.sleepAt;
          Persistent = false;
        };
      };

      systemd.services.scheduled-suspend = {
        serviceConfig.Type = "oneshot";
        # wakeAt is a time of day; pick its next occurrence.
        script = ''
          now=$(${pkgs.coreutils}/bin/date +%s)
          target=$(${pkgs.coreutils}/bin/date -d '${cfg.idle.scheduled.wakeAt}' +%s)
          if [ "$target" -le "$now" ]; then
            target=$(${pkgs.coreutils}/bin/date -d 'tomorrow ${cfg.idle.scheduled.wakeAt}' +%s)
          fi
          ${pkgs.util-linux}/bin/rtcwake -m no -t "$target"
          ${pkgs.systemd}/bin/systemctl suspend
        '';
      };
    })

    (lib.mkIf (cfg.idle.policy == "autosuspend") {
      services.autosuspend = {
        enable = true;
        settings = {
          idle_time = cfg.idle.autosuspend.idleMinutes * 60;
          suspend_cmd =
            if cfg.idle.autosuspend.powerOffAfterHours == null then
              "${pkgs.systemd}/bin/systemctl suspend"
            else
              lib.getExe (suspendThenPowerOff cfg.idle.autosuspend.powerOffAfterHours);
        };
        checks = {
          SessionActivity = {
            class = "ExternalCommand";
            command = lib.getExe sessionActivity;
          };
          LogindSessionsIdle.class = "LogindSessionsIdle";
          Load = {
            class = "Load";
            threshold = cfg.idle.autosuspend.loadThreshold;
          };
        };
      };
    })

    (lib.mkIf cfg.instrument {
      services.below = {
        enable = true;
        collect.ioStats = true;
        retention.time = 30 * 24 * 60 * 60;
      };

      systemd.services.powertop-snapshot = {
        description = "Record device power states and wakeups";
        serviceConfig = {
          ExecStart = lib.getExe powertopSnapshot;
          LogsDirectory = "powertop";
          LogsDirectoryMode = "0750";
          Type = "oneshot";
        };
      };

      systemd.timers.powertop-snapshot = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5m";
          OnUnitActiveSec = "15m";
          Persistent = true;
          RandomizedDelaySec = "30s";
        };
      };

      systemd.tmpfiles.rules = [
        "d /var/log/powertop 0750 root root 30d"
      ];
    })
  ];
}

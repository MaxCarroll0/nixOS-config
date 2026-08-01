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
    ];
    text = ''
      interval="''${1:-5}"
      declare -A before
      for d in /sys/class/powercap/*/; do
        [ -r "$d/energy_uj" ] || continue
        before["$d"]=$(cat "$d/energy_uj")
      done
      if [ ''${#before[@]} -eq 0 ]; then
        echo "no readable powercap domains." >&2
        echo "energy_uj is root-only since Linux 5.10; set" >&2
        echo "local.power.monitoring.userReadable = true, or run this as root." >&2
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

  suspendSoft = softPowerCommand "suspend-soft" "suspend-soft-hardware" "off";
  wakeSoft = softPowerCommand "wake-soft" "wake-soft-hardware" "on";
in

{
  options.local.power = {
    monitoring.enable = lib.mkEnableOption "power and thermal metrics";

    monitoring.grafana = lib.mkEnableOption "a local Grafana for the metrics";

    # Linux 5.10 made these root-only over the PLATYPUS side channel; without
    # this both power-report and the rapl collector see nothing.
    monitoring.userReadable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Relax RAPL energy counters to the powermon group.";
    };

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
        suspendSoft
        wakeSoft
      ]
      ++ (with pkgs; [
        below
        btop
        nvtopPackages.amd
        powertop
        powerstat
        s-tui
        lm_sensors
      ]);

    }

    (lib.mkIf (cfg.wakeOnLan.interface != null) {
      networking.interfaces.${cfg.wakeOnLan.interface}.wakeOnLan.enable = true;
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
        description = "Suspend idle hardware without suspending the system";
        serviceConfig.Type = "oneshot";
        script = ''
          for device in /sys/bus/usb/devices/*; do
            id="$(cat "$device/idVendor" 2>/dev/null || true):$(cat "$device/idProduct" 2>/dev/null || true)"
            if [ "$id" = 258a:1006 ] || [ "$id" = 1d57:ad17 ]; then
              echo 0 > "$device/power/autosuspend_delay_ms"
              echo auto > "$device/power/control"
            fi
          done

          sleep 3

          for device in /sys/bus/usb/devices/*; do
            id="$(cat "$device/idVendor" 2>/dev/null || true):$(cat "$device/idProduct" 2>/dev/null || true)"
            if [ "$id" = 258a:1006 ] || [ "$id" = 1d57:ad17 ]; then
              echo 300000 > "$device/power/autosuspend_delay_ms"
            fi
          done

          for device in /sys/block/*; do
            if [ "$(cat "$device/queue/rotational" 2>/dev/null || true)" = 1 ]; then
              ${pkgs.hdparm}/bin/hdparm -y "/dev/$(basename "$device")"
            fi
          done
        '';
      };

      systemd.services.wake-soft-hardware = {
        description = "Wake hardware without changing the system power state";
        serviceConfig.Type = "oneshot";
        script = ''
          for device in /sys/bus/usb/devices/*; do
            id="$(cat "$device/idVendor" 2>/dev/null || true):$(cat "$device/idProduct" 2>/dev/null || true)"
            if [ "$id" = 258a:1006 ] || [ "$id" = 1d57:ad17 ]; then
              echo on > "$device/power/control"
              echo 300000 > "$device/power/autosuspend_delay_ms"
              echo auto > "$device/power/control"
            fi
          done

          for device in /sys/block/*; do
            if [ "$(cat "$device/queue/rotational" 2>/dev/null || true)" = 1 ]; then
              ${pkgs.coreutils}/bin/dd if="/dev/$(basename "$device")" of=/dev/null bs=512 count=1 status=none
            fi
          done
        '';
      };
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
          suspend_cmd = "${pkgs.systemd}/bin/systemctl suspend";
          # Clear first: writing wakealarm with one already armed fails EBUSY.
          wakeup_cmd = "echo 0 > /sys/class/rtc/rtc0/wakealarm; echo {timestamp:.0f} > /sys/class/rtc/rtc0/wakealarm";
        };
        checks = {
          ActiveConnection = {
            class = "ActiveConnection";
            ports = lib.concatMapStringsSep "," toString cfg.idle.autosuspend.watchPorts;
          };
          Users.class = "Users";
          LogindSessionsIdle.class = "LogindSessionsIdle";
          # Remote builds hold port 22 open, so ActiveConnection covers them.
          # nix-daemon runs persistently and cannot be matched by name.
          Load = {
            class = "Load";
            threshold = cfg.idle.autosuspend.loadThreshold;
          };
        };
      };
    })

    # node_exporter runs as its own user, so it needs the group too.
    (lib.mkIf cfg.monitoring.userReadable {
      users.groups.powermon = { };
      users.users.max.extraGroups = [ "powermon" ];

      services.udev.extraRules = ''
        SUBSYSTEM=="powercap", ACTION=="add", RUN+="${pkgs.coreutils}/bin/chgrp -R powermon /sys%p", RUN+="${pkgs.coreutils}/bin/chmod -R g=u /sys%p"
      '';

      systemd.services.prometheus-node-exporter.serviceConfig.SupplementaryGroups = [ "powermon" ];
    })

    (lib.mkIf cfg.monitoring.enable {
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

      services.prometheus.exporters.node = {
        enable = true;
        listenAddress = "127.0.0.1";
        enabledCollectors = [
          "rapl"
          "hwmon"
          "cpufreq"
          "thermal_zone"
        ];
      };

      services.prometheus = {
        enable = true;
        listenAddress = "127.0.0.1";
        retentionTime = "30d";
        scrapeConfigs = [
          {
            job_name = "node";
            static_configs = [
              { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ]; }
            ];
          }
        ];
      };
    })

    (lib.mkIf (cfg.monitoring.enable && cfg.monitoring.grafana) {
      services.grafana = {
        enable = true;
        settings.server = {
          http_addr = "127.0.0.1";
          http_port = 3000;
        };
      };
    })
  ];
}

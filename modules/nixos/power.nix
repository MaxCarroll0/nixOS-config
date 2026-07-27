# Idle power policy and power measurement.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.power;

  # RAPL counters are per-domain energy in microjoules; watts is the delta.
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
        # The counter is finite and wraps; fold it back rather than dropping it.
        if [ "$delta" -lt 0 ]; then
          range=$(cat "$d/max_energy_range_uj" 2>/dev/null || echo 0)
          [ "$range" -gt 0 ] || continue
          delta=$(( delta + range ))
        fi
        printf '%-24s %6.2f W\n' "$name" "$(echo "scale=2; $delta / 1000000 / $interval" | bc)"
      done
    '';
  };
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

    idle.allowHostingDowntime = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow a sleeping policy while hosting, accepting the outage.";
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
          # `or` so this module stays importable without server/web.nix.
          assertion =
            ((config.local.web.public.enable or false) && !cfg.idle.allowHostingDowntime)
            -> cfg.idle.policy == "always-on";
          message = "Public hosting with idle.policy \"${cfg.idle.policy}\": a suspended host serves no pages and nothing can wake it remotely. Use \"always-on\" or set idle.allowHostingDowntime.";
        }
        {
          assertion = (cfg.wakeOnLan.interface == null) == (cfg.wakeOnLan.mac == null);
          message = "local.power.wakeOnLan needs both interface and mac, or neither.";
        }
      ];

      warnings =
        lib.optional
          (
            (config.local.web.public.enable or false)
            && cfg.idle.allowHostingDowntime
            && cfg.idle.policy != "always-on"
          )
          "idle.policy \"${cfg.idle.policy}\" with public hosting on: the site is down whenever this host sleeps."
        ++ lib.optional (
          cfg.idle.policy != "always-on" && cfg.wakeOnLan.mac == null
        ) "idle.policy \"${cfg.idle.policy}\" with no Wake-on-LAN, so nothing can wake this host remotely.";

      environment.systemPackages = [
        powerReport
      ]
      ++ (with pkgs; [
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
      '';
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
        # Next occurrence of wakeAt, not tomorrow's: suspending at 01:00 with a
        # wake at 08:00 must mean 7 hours, not 31.
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
          # A remote build arrives over SSH and holds port 22 for its duration,
          # so ActiveConnection covers it. Matching nix-daemon by name cannot:
          # it runs persistently, so the host would never suspend.
          Load = {
            class = "Load";
            threshold = cfg.idle.autosuspend.loadThreshold;
          };
        };
      };
    })

    # node_exporter runs as its own user, so a wheel-only relaxation would fix
    # the CLI and leave the rapl collector silently blind.
    (lib.mkIf cfg.monitoring.userReadable {
      users.groups.powermon = { };
      users.users.max.extraGroups = [ "powermon" ];

      services.udev.extraRules = ''
        SUBSYSTEM=="powercap", ACTION=="add", RUN+="${pkgs.coreutils}/bin/chgrp -R powermon /sys%p", RUN+="${pkgs.coreutils}/bin/chmod -R g=u /sys%p"
      '';

      systemd.services.prometheus-node-exporter.serviceConfig.SupplementaryGroups = [ "powermon" ];
    })

    (lib.mkIf cfg.monitoring.enable {
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

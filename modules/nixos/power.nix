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
      sleep "$interval"
      for d in /sys/class/powercap/*/; do
        [ -r "$d/energy_uj" ] || continue
        name=$(cat "$d/name" 2>/dev/null || basename "$d")
        after=$(cat "$d/energy_uj")
        delta=$(( after - ''${before["$d"]} ))
        [ "$delta" -lt 0 ] && continue
        printf '%-24s %6.2f W\n' "$name" "$(echo "scale=2; $delta / 1000000 / $interval" | bc)"
      done
    '';
  };
in

{
  options.local.power = {
    monitoring.enable = lib.mkEnableOption "power and thermal metrics";

    monitoring.grafana = lib.mkEnableOption "a local Grafana for the metrics";

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
          assertion = config.local.web.public.enable -> cfg.idle.policy == "always-on";
          message = ''
            local.web.public is enabled but local.power.idle.policy is
            "${cfg.idle.policy}". A suspended host serves no pages and nothing on
            the internet can wake it. Set the policy to "always-on" or accept the
            outage by overriding this assertion.
          '';
        }
      ];

      environment.systemPackages = [ powerReport ] ++ (with pkgs; [
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
        script = ''
          ${pkgs.util-linux}/bin/rtcwake -m no -t "$(${pkgs.coreutils}/bin/date -d 'tomorrow ${cfg.idle.scheduled.wakeAt}' +%s)"
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
          wakeup_cmd = "echo {timestamp:.0f} > /sys/class/rtc/rtc0/wakealarm";
        };
        checks = {
          ActiveConnection = {
            class = "ActiveConnection";
            ports = lib.concatMapStringsSep "," toString cfg.idle.autosuspend.watchPorts;
          };
          Users.class = "Users";
          Load.class = "Load";
          LogindSessionsIdle.class = "LogindSessionsIdle";
          NixBuilds = {
            class = "Processes";
            processes = "nix-daemon nix-build nix";
          };
        };
      };
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

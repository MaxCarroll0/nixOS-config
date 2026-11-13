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

  driveLabels =
    writeCollector "drive-labels"
      [
        pkgs.util-linux
        pkgs.gawk
      ]
      (builtins.readFile ./drive-labels.sh);

  smartHealth =
    writeCollector "smart-health"
      [
        pkgs.smartmontools
        pkgs.gawk
        pkgs.jq
      ]
      (builtins.replaceStrings [ "@probe@" "@skipDevices@" "@stateDir@" "@refreshSeconds@" ] [ probe skipDevices stateDir (toString (cfg.refreshMinutes * 60)) ] (builtins.readFile ./smart-health.sh));

  selfTest = pkgs.writeShellApplication {
    name = "drive-selftest";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.smartmontools
      pkgs.gawk
      pkgs.jq
      pkgs.util-linux
    ];
    text = builtins.replaceStrings [ "@stateDir@" "@textfileDir@" "@fromHour@" "@toHour@" "@probe@" "@skipDevices@" "@longSeconds@" "@preSpindownSeconds@" "@shortSeconds@" ] [ stateDir collectors.textfileDir (toString cfg.selfTest.longWindowFromHour) (toString cfg.selfTest.longWindowToHour) probe skipDevices (toString (cfg.selfTest.longIntervalDays * 86400)) (toString (cfg.selfTest.preSpindownMinutes * 60)) (toString (cfg.selfTest.shortIntervalHours * 3600)) ] (builtins.readFile ./drive-selftest.sh);
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

        systemd.services.textfile-drive-labels = lib.mkMerge [
          (collectorService driveLabels)
          {
            description = "Publish a persistent name and size for every block device";
            wantedBy = [ "multi-user.target" ];
          }
        ];

        systemd.timers.textfile-drive-labels = collectorTimer "5m";
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

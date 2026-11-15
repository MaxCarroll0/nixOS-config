# Disk ledger and continuous collector, store retention and generation expiry.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.disk;
  pressure = cfg.pressure;
  home = "/home/${cfg.user}";
  uid = toString cfg.uid;
  gib = 1024 * 1024 * 1024;

  retention = pkgs.writeShellApplication {
    name = "project-closure-retention";
    runtimeInputs = [
      config.nix.package
      pkgs.angrr
      pkgs.python3
    ];
    text = ''
      exec python3 ${./project-closure-retention.py} "$@"
    '';
  };

  collect = pkgs.writeShellApplication {
    name = "store-collect";
    runtimeInputs = [
      config.nix.package
      pkgs.python3
    ];
    text = ''
      exec python3 ${./store-collect.py} "$@"
    '';
  };

  stateDir = "/var/lib/disk-ledger";
  targetFile = "${home}/.config/caelestia/disk-target";

  ledger = pkgs.writeShellApplication {
    name = "disk-ledger";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.e2fsprogs
      pkgs.git
      pkgs.python3
      pkgs.util-linux
    ];
    text = ''
      export RETENTION_MODULE=${./project-closure-retention.py}
      export COLLECT_MODULE=${./store-collect.py}
      export TREE_MODULE=${./disk-tree.py}
      export RECLAIM_MODULE=${./reclaim.py}
      export PYTHONUNBUFFERED=1
      export PYTHONDONTWRITEBYTECODE=1
      export LEDGER_HOME=${home}
      export LEDGER_USER=${cfg.user}
      export LEDGER_TARGET_BYTES=${toString (pressure.minFreeGiB * gib)}
      export LEDGER_TARGET_FILE=${targetFile}
      export LEDGER_EMERGENCY_BYTES=${toString (config.nix.settings.min-free or (5 * gib))}
      export LEDGER_COLLECT=${if pressure.enable then "1" else "0"}
      export LEDGER_RUNTIME_DIR=/run/user/${uid}
      export LEDGER_STATE_DIR=${stateDir}
      export LEDGER_UID=${uid}
      export LEDGER_TEXTFILE=/var/lib/node-exporter-textfile/disk-ledger.prom
      export LEDGER_OFFLOAD_DIR=${if cfg.offload.enable then "${home}/offload" else ""}
      exec python3 ${./disk-ledger.py}
    '';
  };

  resourceLimits = {
    CPUWeight = "idle";
    IOWeight = 10;
    MemoryHigh = "1.5G";
  };
in

{
  options.local.disk = {
    user = lib.mkOption {
      type = lib.types.str;
      default = "max";
      description = "User whose home, caches and runtime directory the disk units manage.";
    };

    offload.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.networking.hostName == "desktopnew";
      description = "Whether ~/offload build trees are in the ledger and reclaimed under pressure.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "Numeric uid of local.disk.user, whose runtime directory receives the ledger.";
    };

    retention = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = retention;
      description = "The project-closure-retention command used by nightly and pressure runs.";
    };

    pressure = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.networking.hostName == "laptop";
        description = "Whether the continuous collector keeps free space at the target.";
      };

      minFreeGiB = lib.mkOption {
        type = lib.types.int;
        default = if config.networking.hostName == "desktopnew" then 40 else 20;
        description = "Free space in GiB on /nix/store that continuous reclaim keeps, plus a 512 MiB margin.";
      };
    };
  };

  config = {
    nix.settings.keep-derivations = lib.mkIf pressure.enable false;

    environment.systemPackages = [ collect ];

    systemd.tmpfiles.rules = [ "d ${stateDir} 0755 root root -" ];

    systemd.services.generation-expire = lib.mkIf (!pressure.enable) {
      restartIfChanged = false;
      description = "Keep the last 10 generations of every profile";
      path = [ config.nix.package ];
      serviceConfig = resourceLimits // {
        Type = "oneshot";
      };
      script = ''
        for profile in /nix/var/nix/profiles/system /nix/var/nix/profiles/default \
            /nix/var/nix/profiles/per-user/*/* ${home}/.local/state/nix/profiles/*; do
          case "$profile" in *-link) continue ;; esac
          [ -L "$profile" ] || continue
          nix-env --profile "$profile" --delete-generations +10
        done
      '';
    };

    systemd.timers.generation-expire = lib.mkIf (!pressure.enable) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };

    systemd.services.disk-ledger = {
      description = "Disk ledger for the storage tab and metrics, and the continuous collector";
      wantedBy = [ "multi-user.target" ];
      after = [ "nix-daemon.socket" ];
      serviceConfig = resourceLimits // {
        Type = "simple";
        ExecStart = lib.getExe ledger;
        Restart = "always";
        RestartSec = 30;
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };
  };
}

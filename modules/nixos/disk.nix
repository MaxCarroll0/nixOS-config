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

  daemon = pkgs.callPackage ../../pkgs/disk-ledger.nix { };

  stateDir = "/var/lib/disk-ledger";
  targetFile = "${home}/.config/caelestia/disk-target";

  ledger = pkgs.writeShellApplication {
    name = "disk-ledger";
    runtimeInputs = [
      config.nix.package
      pkgs.bash
      pkgs.coreutils
      pkgs.e2fsprogs
      pkgs.git
      pkgs.openssh
      pkgs.util-linux
    ];
    text = ''
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
      exec ${lib.getExe daemon} serve
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

    ledger.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether the disk ledger daemon and its continuous collector run on this host.";
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
        default = true;
        description = "Whether the continuous collector keeps free space at the target.";
      };

      minFreeGiB = lib.mkOption {
        type = lib.types.int;
        default = if config.networking.hostName == "desktopnew" then 40 else 20;
        description = "Free space in GiB on /nix/store that continuous reclaim keeps, plus a 512 MiB margin.";
      };
    };
  };

  config = lib.mkIf cfg.ledger.enable {
    nix.settings.keep-derivations = lib.mkIf pressure.enable false;

    environment.systemPackages = [ daemon ];

    systemd.tmpfiles.rules = [ "d ${stateDir} 0755 root root -" ];

    systemd.services.disk-ledger = {
      description = "Disk ledger for the storage tab and metrics, and the continuous collector";
      wantedBy = [ "multi-user.target" ];
      requires = [ "sysinit.target" ];
      after = [
        "nix-daemon.socket"
        "basic.target"
        "multi-user.target"
        "graphical.target"
      ];
      conflicts = [ "shutdown.target" ];
      before = [ "shutdown.target" ];
      unitConfig.DefaultDependencies = false;
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

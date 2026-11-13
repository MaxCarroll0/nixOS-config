# Disk pressure, tiered store retention, scratch sweeping and the disk ledger.

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

  scratchClean = pkgs.writeShellApplication {
    name = "project-scratch-clean";
    runtimeInputs = [
      pkgs.git
      pkgs.python3
    ];
    text = ''
      export SCRATCH_OFFLOAD_DIR=${if cfg.offload.enable then "${home}/offload" else ""}
      export SCRATCH_MIN_FREE_BYTES=${toString (pressure.minFreeGiB * gib)}
      exec python3 ${./project-scratch-clean.py} "$@"
    '';
  };

  ledger = pkgs.writeShellApplication {
    name = "disk-ledger";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.python3
    ];
    text = ''
      export RETENTION_MODULE=${./project-closure-retention.py}
      export LEDGER_HOME=${home}
      export LEDGER_TARGET_BYTES=${toString (pressure.minFreeGiB * gib)}
      export LEDGER_RUNTIME_DIR=/run/user/${uid}
      export LEDGER_UID=${uid}
      export LEDGER_TEXTFILE=/var/lib/node-exporter-textfile/disk-ledger.prom
      export LEDGER_OFFLOAD_DIR=${if cfg.offload.enable then "${home}/offload" else ""}
      exec python3 ${./disk-ledger.py}
    '';
  };

  freeGiB = ''df --output=avail -B1G /nix/store | tail -n1'';

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
        description = "Whether free space below the target triggers retention and bounded collection.";
      };

      minFreeGiB = lib.mkOption {
        type = lib.types.int;
        default = if config.networking.hostName == "desktopnew" then 40 else 20;
        description = "Free space in GiB on /nix/store below which pressure reclaim runs.";
      };

      maxFreedGiB = lib.mkOption {
        type = lib.types.int;
        default = 40;
        description = "Upper bound in GiB on what one pressure run may free.";
      };
    };
  };

  config = {
    environment.systemPackages = [ scratchClean ];

    systemd.services.nh-clean = {
      preStart = ''
        ${cfg.retention}/bin/project-closure-retention --apply
      '';
      serviceConfig = resourceLimits // lib.optionalAttrs pressure.enable {
        ExecCondition = "${pkgs.bash}/bin/sh -c 'test \"$(${freeGiB})\" -lt ${toString pressure.minFreeGiB}'";
      };
    };

    systemd.services.disk-pressure = lib.mkIf pressure.enable {
      description = "Reclaim store space when free space is below target";
      path = [
        config.nix.package
        pkgs.coreutils
      ];
      serviceConfig = resourceLimits // {
        Type = "oneshot";
      };
      script = ''
        free=$(${freeGiB})
        if [ "$free" -ge ${toString pressure.minFreeGiB} ]; then
          exit 0
        fi
        deficit=$(( ${toString pressure.minFreeGiB} - free + 5 ))
        if [ "$deficit" -gt ${toString pressure.maxFreedGiB} ]; then
          deficit=${toString pressure.maxFreedGiB}
        fi
        ${cfg.retention}/bin/project-closure-retention --apply --need-gib "$deficit" --max-freed-gib ${toString pressure.maxFreedGiB}
        nix-collect-garbage --max-freed $(( deficit * ${toString gib} ))
      '';
    };

    systemd.timers.disk-pressure = lib.mkIf pressure.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "15min";
      };
    };

    systemd.paths.disk-pressure = lib.mkIf pressure.enable {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = [
          "${home}/Videos"
          "${home}/Downloads"
        ];
        Unit = "disk-pressure.service";
      };
    };

    systemd.services.disk-ledger = {
      description = "Write the disk ledger for the performance tab and metrics";
      serviceConfig = resourceLimits // {
        Type = "oneshot";
        ExecStart = lib.getExe ledger;
      };
    };

    systemd.timers.disk-ledger = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "15min";
      };
    };

    systemd.user.services.project-scratch-clean = {
      description = "Remove rederivable build outputs, shell temp dirs and caches";
      serviceConfig = resourceLimits // {
        Type = "oneshot";
        ExecStart = "${lib.getExe scratchClean} --apply";
      };
    };

    systemd.user.timers.project-scratch-clean = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
      };
    };
  };
}

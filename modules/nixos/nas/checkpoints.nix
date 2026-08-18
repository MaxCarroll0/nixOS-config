# NILFS2 checkpoints: promotion, the SMB-visible rolling window, manual pruning and metrics.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas;
  ccfg = cfg.checkpoints;
  scfg = cfg.storage;

  nilfsBranches = lib.filterAttrs (_: d: d.fsType == "nilfs2") scfg.dataDisks;

  branchArgs = lib.concatMapStringsSep " " (
    name: "--branch ${scfg.diskRoot}/${name}"
  ) (lib.attrNames nilfsBranches);

  tool = pkgs.writeShellApplication {
    name = "nas-checkpoints";
    runtimeInputs = [
      pkgs.python3
      pkgs.nilfs-utils
      pkgs.util-linux
    ];
    text = ''
      exec python3 ${./nas-checkpoints.py} ${branchArgs} \
        --snapshot-dir ${ccfg.snapshotDir} "$@"
    '';
  };
in

{
  options.local.nas.checkpoints = {
    enable = lib.mkEnableOption "NILFS2 checkpoint promotion, rolling window and metrics";

    snapshotDir = lib.mkOption {
      type = lib.types.str;
      default = "snapshots";
      description = "Directory inside each branch where the visible window is mounted.";
    };

    window = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = "Generations exposed for SMB Previous Versions. Each costs one mount per branch.";
    };

    promoteInterval = lib.mkOption {
      type = lib.types.str;
      default = "15m";
      description = "How often checkpoints are promoted so the collector cannot reclaim them.";
    };

    metricsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter-textfile/nas-checkpoints.prom";
      description = "Textfile collector output for checkpoint counts and age.";
    };

    cleanerWindow = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 04:45:00";
      description = "When the garbage collector may run; inside the SnapRAID window so it never wakes a sleeping disk.";
    };
  };

  config = lib.mkIf (cfg.enable && ccfg.enable && nilfsBranches != { }) {
    environment.systemPackages = [
      tool
      pkgs.nilfs-utils
    ];

    systemd.services.nas-checkpoint-promote = {
      description = "Promote NILFS2 checkpoints so they survive collection";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe tool} promote";
        ExecStartPost = "${lib.getExe tool} metrics --output ${ccfg.metricsFile}";
        Nice = 15;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.nas-checkpoint-promote = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = ccfg.promoteInterval;
        Persistent = false;
      };
    };

    systemd.services.nas-checkpoint-window = {
      description = "Expose the newest generations for SMB Previous Versions";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe tool} window --window ${toString ccfg.window}";
        Nice = 15;
      };
    };

    systemd.timers.nas-checkpoint-window = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "6m";
        OnUnitActiveSec = ccfg.promoteInterval;
        Persistent = false;
      };
    };

    systemd.services.nas-checkpoint-clean = {
      description = "NILFS2 garbage collection, confined to the nightly window";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.concatMapStringsSep " ; " (
          name: "${pkgs.nilfs-utils}/bin/nilfs-clean ${scfg.diskRoot}/${name}"
        ) (lib.attrNames nilfsBranches);
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.nas-checkpoint-clean = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = ccfg.cleanerWindow;
        Persistent = false;
        RandomizedDelaySec = "10m";
      };
    };
  };
}

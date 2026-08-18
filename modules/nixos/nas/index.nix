# NAS browse index: SQLite cache of the file tree, thumbnails and version counts.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas;
  icfg = cfg.index;

  indexer = pkgs.writeShellApplication {
    name = "nas-index";
    runtimeInputs = [
      (pkgs.python3.withPackages (_: [ ]))
      pkgs.btrfs-progs
      pkgs.imagemagick
    ];
    text = ''
      exec python3 ${./nas-index.py} \
        --db ${icfg.stateDir}/index.db \
        --data-root ${cfg.dataRoot} \
        --thumb-dir ${icfg.stateDir}/thumbs \
        --thumb-size ${toString icfg.thumbnailSize} \
        --metrics-file ${icfg.metricsFile} \
        ${lib.optionalString (!icfg.thumbnails) "--no-thumbnails"} "$@"
    '';
  };
in

{
  options.local.nas.index = {
    enable = lib.mkEnableOption "the browse index, thumbnailer and per-user usage metrics";

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nas-index";
      description = "Where the index database and thumbnails live; kept off the array.";
    };

    thumbnails = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Generate thumbnails for images as they are indexed.";
    };

    thumbnailSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 256;
      description = "Longest edge of a generated thumbnail, in pixels.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "15m";
      description = "How often the index reconciles against the data tree.";
    };

    metricsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter-textfile/nas-index.prom";
      description = "Textfile collector output carrying per-user usage.";
    };
  };

  config = lib.mkIf (cfg.enable && icfg.enable) {
    environment.systemPackages = [ indexer ];

    systemd.tmpfiles.rules = [
      "d ${icfg.stateDir} 0755 root root - -"
      "d ${icfg.stateDir}/thumbs 0755 root root - -"
    ];

    systemd.services.nas-index = {
      description = "Reconcile the NAS browse index";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe indexer;
        Nice = 10;
        IOSchedulingClass = "idle";
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ReadWritePaths = [
          icfg.stateDir
          (builtins.dirOf icfg.metricsFile)
        ];
        ReadOnlyPaths = [ cfg.dataRoot ];
      };
    };

    systemd.timers.nas-index = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = icfg.interval;
        Persistent = true;
        RandomizedDelaySec = "2m";
      };
    };
  };
}

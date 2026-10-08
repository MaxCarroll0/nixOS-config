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

  watchStamp = "${icfg.stateDir}/watch.stamp";
  watchPending = "${icfg.stateDir}/watch.pending";

  changeGate = pkgs.writeShellApplication {
    name = "nas-index-changed";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.diffutils
    ];
    text = ''
      stat -c '%n %s %Y' ${cfg.versions.stateDir}/*.jsonl > ${watchPending} 2>/dev/null || true
      [ -n "$(find ${watchStamp} -mmin -1440 2>/dev/null)" ] || exit 0
      cmp -s ${watchPending} ${watchStamp} && exit 1
      exit 0
    '';
  };

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

    # Each walk is block I/O on the fullest branch, which resets enforce-disk-idle's
    # 3600s gate, so anything under an hour makes that disk structurally unparkable.
    interval = lib.mkOption {
      type = lib.types.str;
      default = "6h";
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
      }
      // lib.optionalAttrs cfg.versions.enable {
        ExecCondition = lib.getExe changeGate;
        ExecStartPost = "${pkgs.coreutils}/bin/mv ${watchPending} ${watchStamp}";
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

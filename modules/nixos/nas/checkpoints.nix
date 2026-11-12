# NILFS2 history: checkpoint index, per-file history, the time view and its metrics.

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
  branchPaths = map (name: "${scfg.diskRoot}/${name}") (lib.attrNames nilfsBranches);
  stateDir = dirOf ccfg.indexDb;
  grafana = config.services.grafana.enable;

  mountUnit =
    name:
    "${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" "${scfg.diskRoot}/${name}")}.mount";

  streamRoots = lib.mapAttrsToList (name: st: "${name}=${st.root}") (cfg.streams or { });

  atArgs =
    lib.concatMap (b: [
      "--branch"
      b
    ]) branchPaths
    ++ [
      "--index"
      ccfg.indexDb
      "--lock"
      cfg.nilfsWriteLock
      "--suspend"
      ccfg.suspendFile
      "--metrics"
      ccfg.metricsFile
      "--pool"
      cfg.dataRoot
      "--view"
      ccfg.viewDir
      "--gap-default"
      (toString ccfg.landmarkGap)
      "--rotate-bytes"
      (toString ccfg.rotateBytes)
      "--reclaim-free"
      (toString (ccfg.reclaimFreePercent / 100.0))
    ]
    ++ lib.concatMap (p: [
      "--historyless"
      p
    ]) ccfg.historyless
    ++ lib.optionals (streamRoots != [ ]) (
      [
        "--points"
        cfg.streamPointsDb
      ]
      ++ lib.concatMap (r: [
        "--stream"
        r
      ]) streamRoots
    );

  at = pkgs.writeShellApplication {
    name = "nas-at";
    text = ''exec ${lib.getExe pkgs.nas-at} ${lib.escapeShellArgs atArgs} "$@"'';
  };

  lowSpace = pkgs.writeShellApplication {
    name = "nas-low-space";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
      util-linux
    ];
    text = ''
      last=-60
      while sleep 15; do
        for branch in ${lib.escapeShellArgs branchPaths}; do
          mountpoint -q "$branch" || continue
          read -r avail total < <(stat -f -c '%a %b' "$branch")
          if (( avail * 100 < total * ${toString ccfg.reclaimFreePercent} && SECONDS - last >= 60 )); then
            systemctl start --no-block nas-checkpoint-promote.service
            last=$SECONDS
          fi
        done
      done
    '';
  };

  unmountView = pkgs.writeShellApplication {
    name = "nas-at-view-unmount";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      util-linux
    ];
    text = ''
      umount -l ${ccfg.viewDir} 2>/dev/null || true
      findmnt -rno TARGET \
        | awk 'index($0, "/run/nas-at/") == 1 || $0 ~ "^${scfg.diskRoot}/[^/]+/snapshots/@GMT-"' \
        | sort -r | while read -r target; do
          umount "$target" || umount -l "$target" || true
          rmdir "$target" 2>/dev/null || true
        done
      for branch in ${lib.escapeShellArgs branchPaths}; do
        rmdir "$branch"/snapshots/@GMT-* "$branch/snapshots" 2>/dev/null || true
      done
    '';
  };

  background = {
    Type = "oneshot";
    Nice = 15;
    IOSchedulingClass = "idle";
  };
in

{
  options.local.nas.checkpoints = {
    enable = lib.mkEnableOption "NILFS2 per-file history, the time view and metrics";

    indexDb = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nas-checkpoints/index.db";
      description = "History index: checkpoints, block lifetimes, paths and rules per branch.";
    };

    viewDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/nas-at";
      description = "Read-only time view: <viewDir>/<time>/<path>, also SMB Previous Versions.";
    };

    historyless = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "tmp"
        ".cache"
        "*/.cache"
      ];
      description = "Pool-relative glob prefixes that keep no history.";
    };

    landmarkGap = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Idle seconds that end an editing session, a landmark every stitch keeps.";
    };

    rotateBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 64 * 1024 * 1024;
      description = "Event file size at which the watcher is restarted onto a fresh file.";
    };

    walkCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 04:30:00";
      description = "When the full path walk runs; inside the SnapRAID window so disks already spin.";
    };

    atPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = at;
      description = "The nas-at command with this host's branches baked in.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "15m";
      description = "How often the history pass runs.";
    };

    reclaimFreePercent = lib.mkOption {
      type = lib.types.ints.between 1 99;
      default = 15;
      description = "Free space below which a branch is reclaimed, checked every 15 s.";
    };

    suspendFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/nas-promote-suspended";
      description = "While this file exists, the history pass and new view mounts are skipped.";
    };

    metricsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter-textfile/nas-checkpoints.prom";
      description = "Textfile collector output for checkpoints, history bytes and branch fullness.";
    };
  };

  config = lib.mkIf (cfg.enable && ccfg.enable && nilfsBranches != { }) {
    environment.systemPackages = [
      at
      pkgs.nilfs-utils
      pkgs.fatrace
    ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 root ${if grafana then "grafana" else "root"} - -"
      "d ${stateDir}/events 0750 root root - -"
    ];

    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (
        name: _:
        lib.nameValuePair "nas-history-watch-${name}" {
          description = "Record writes on ${name} for per-file history";
          wantedBy = [
            (mountUnit name)
            "multi-user.target"
          ];
          partOf = [ (mountUnit name) ];
          after = [ (mountUnit name) ];
          serviceConfig = {
            ExecStartPre = "${pkgs.coreutils}/bin/rm -f ${stateDir}/events/${name}.jsonl";
            ExecStart = "${pkgs.fatrace}/bin/fatrace -c -j -f W+D<> -t -t -o ${stateDir}/events/${name}.jsonl";
            WorkingDirectory = "${scfg.diskRoot}/${name}";
            Restart = "on-failure";
            RestartSec = 30;
            Nice = 10;
            MemoryMax = "32M";
          };
          unitConfig.ConditionPathIsMountPoint = "${scfg.diskRoot}/${name}";
        }
      ) nilfsBranches)

      {
        nas-at-view = {
          description = "Read-only time view of the NAS at ${ccfg.viewDir}";
          wantedBy = map mountUnit (lib.attrNames nilfsBranches) ++ [ "multi-user.target" ];
          partOf = map mountUnit (lib.attrNames nilfsBranches);
          after = map mountUnit (lib.attrNames nilfsBranches);
          serviceConfig = {
            ExecStartPre = lib.getExe unmountView;
            ExecStart = "${lib.getExe at} serve";
            ExecStopPost = lib.getExe unmountView;
            Restart = "on-failure";
            RestartSec = 10;
            Nice = 5;
          };
        };

        nas-checkpoint-promote = {
          description = "NILFS2 history pass: promote, scan, apply rules, reclaim, metrics";
          restartIfChanged = false;
          serviceConfig = background // {
            ExecStart = "${lib.getExe at} pass";
          };
          unitConfig.ConditionPathExists = "!${ccfg.suspendFile}";
        };

        nas-low-space = {
          description = "Start the history pass as soon as a NILFS2 branch runs low on space";
          wantedBy = [ "multi-user.target" ];
          after = map mountUnit (lib.attrNames nilfsBranches);
          serviceConfig = {
            ExecStart = lib.getExe lowSpace;
            Restart = "always";
            RestartSec = 30;
            Nice = 10;
            MemoryMax = "16M";
          };
        };

        nas-history-walk = {
          description = "Full path walk for NILFS2 history, recovering events a watcher missed";
          restartIfChanged = false;
          serviceConfig = background // {
            ExecStart = "${lib.getExe at} pass --walk";
            Nice = 19;
          };
          unitConfig.ConditionPathExists = "!${ccfg.suspendFile}";
        };
      }
    ];

    systemd.timers.nas-checkpoint-promote = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "5m";
        OnUnitActiveSec = ccfg.interval;
        Persistent = false;
      };
    };

    systemd.timers.nas-history-walk = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = ccfg.walkCalendar;
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };
  };
}

# NILFS2 checkpoints: promotion is retention, plus the SMB-visible window and metrics.

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

  mountUnit =
    name:
    "${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" "${scfg.diskRoot}/${name}")}.mount";

  forEachBranch = body: ''
    branches=( ${lib.escapeShellArgs branchPaths} )
    for branch in "''${branches[@]}"; do
      mountpoint -q "$branch" || continue
      device=$(findmnt -no SOURCE "$branch" | head -1) || continue
      [ -n "$device" ] || continue
      [ -d "/sys/fs/nilfs2/$(basename "$(readlink -f "$device")")" ] || continue
      ${body}
    done
  '';

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
      "--pool"
      cfg.dataRoot
      "--view"
      ccfg.viewDir
      "--hide"
      ccfg.snapshotDir
    ]
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
    runtimeInputs = [
      pkgs.nilfs-utils
      pkgs.util-linux
    ];
    text = ''
      exec ${
        pkgs.python3.withPackages (ps: [ ps.fusepy ])
      }/bin/python3 ${./nas-at.py} ${lib.escapeShellArgs atArgs} "$@"
    '';
  };

  promote = pkgs.writeShellApplication {
    name = "nas-checkpoint-promote";
    text = "exec ${lib.getExe at} index --promote";
  };

  window = pkgs.writeShellApplication {
    name = "nas-checkpoint-window";
    text = "exec ${lib.getExe at} window --snapshot-dir ${ccfg.snapshotDir} --bucket ${toString ccfg.windowBucketSeconds} --generations ${toString ccfg.window}";
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
      findmnt -rno TARGET | awk 'index($0, "/run/nas-at/") == 1' | sort -r | while read -r target; do
        umount "$target" || umount -l "$target" || true
        rmdir "$target" 2>/dev/null || true
      done
    '';
  };

  metrics = pkgs.writeShellApplication {
    name = "nas-checkpoint-metrics";
    runtimeInputs = [
      pkgs.nilfs-utils
      pkgs.util-linux
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      tmp=${ccfg.metricsFile}.tmp
      {
        echo '# HELP nas_checkpoints Checkpoints on this branch.'
        echo '# TYPE nas_checkpoints gauge'
        echo '# HELP nas_checkpoint_snapshots Checkpoints promoted to snapshots, which are retained forever.'
        echo '# TYPE nas_checkpoint_snapshots gauge'
        echo '# HELP nas_checkpoints_exposed Generations mounted for SMB Previous Versions.'
        echo '# TYPE nas_checkpoints_exposed gauge'
        echo '# HELP nas_branch_used_ratio Space used, which only ever grows while history is retained.'
        echo '# TYPE nas_branch_used_ratio gauge'
        echo '# HELP nas_branch_size_bytes Branch capacity, for projecting when writes will stop.'
        echo '# TYPE nas_branch_size_bytes gauge'
        echo '# HELP nas_metrics_timestamp_seconds When this file was last written.'
        echo '# TYPE nas_metrics_timestamp_seconds gauge'
        ${forEachBranch ''
          label=$(basename "$branch")
          sysfs=/sys/fs/nilfs2/$(basename "$(readlink -f "$device")")/checkpoints
          total=$(cat "$sysfs/checkpoints_number")
          snaps=$(cat "$sysfs/snapshots_number")
          if [ -d "$branch/${ccfg.snapshotDir}" ]; then
            shown=$(find "$branch/${ccfg.snapshotDir}" -maxdepth 1 -name '@GMT-*' | wc -l)
          else
            shown=0
          fi
          read -r used size <<<"$(df -B1 --output=used,size "$branch" | tail -1)" || continue
          case "$used$size" in *[!0-9]* | "") continue ;; esac
          [ "$size" -gt 0 ] || continue

          echo "nas_checkpoints{branch=\"$label\"} $total"
          echo "nas_checkpoint_snapshots{branch=\"$label\"} $snaps"
          echo "nas_checkpoints_exposed{branch=\"$label\"} $shown"
          echo "nas_branch_used_ratio{branch=\"$label\"} $(awk -v u="$used" -v s="$size" 'BEGIN{printf "%.6f", u/s}')"
          echo "nas_branch_size_bytes{branch=\"$label\"} $size"
        ''}
        echo "nas_metrics_timestamp_seconds $(date +%s)"
      } > "$tmp"

      if awk '!/^#/ && NF && ($NF == "" || $NF + 0 != $NF) { bad = 1 } END { exit bad }' "$tmp"; then
        mv "$tmp" ${ccfg.metricsFile}
      else
        rm -f "$tmp"
        echo "refusing to publish malformed metrics; keeping the previous file" >&2
        exit 1
      fi
    '';
  };
in

{
  options.local.nas.checkpoints = {
    enable = lib.mkEnableOption "NILFS2 checkpoint retention, the SMB window and metrics";

    snapshotDir = lib.mkOption {
      type = lib.types.str;
      default = "snapshots";
      description = "Directory inside each branch where the visible window is mounted.";
    };

    window = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = "Generations exposed for SMB Previous Versions. Versioning does not depend on this.";
    };

    windowBucketSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "One SMB generation per bucket, so a busy stream cannot crowd out older ones.";
    };

    indexDb = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nas-checkpoints/index.db";
      description = "Incremental checkpoint index: cno and epoch per branch.";
    };

    viewDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/nas-at";
      description = "Read-only time view: <viewDir>/<ISO time>/<path>.";
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
      description = "How often checkpoints are promoted and the window refreshed.";
    };

    suspendFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/nas-promote-suspended";
      description = "While this file exists, promotion is skipped; use it during bulk ingest.";
    };

    metricsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter-textfile/nas-checkpoints.prom";
      description = "Textfile collector output for checkpoint counts and branch fullness.";
    };
  };

  config = lib.mkIf (cfg.enable && ccfg.enable && nilfsBranches != { }) {
    environment.systemPackages = [
      promote
      window
      metrics
      at
      pkgs.nilfs-utils
    ];

    systemd.tmpfiles.rules = [ "d ${dirOf ccfg.indexDb} 0750 root root - -" ];

    systemd.services.nas-at-view = {
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

    systemd.services.nas-checkpoint-promote = {
      description = "Retain every NILFS2 checkpoint by promoting it";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe promote;
        ExecStartPost = [
          (lib.getExe window)
          (lib.getExe metrics)
        ];
        Nice = 15;
        IOSchedulingClass = "idle";
      };
      unitConfig.ConditionPathExists = "!${ccfg.suspendFile}";
    };

    systemd.timers.nas-checkpoint-promote = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "5m";
        OnUnitActiveSec = ccfg.interval;
        Persistent = false;
      };
    };
  };
}

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

  forEachBranch = body: ''
    branches=( ${lib.escapeShellArgs branchPaths} )
    for branch in "''${branches[@]}"; do
      mountpoint -q "$branch" || continue
      device=$(findmnt -no SOURCE "$branch" | head -1) || continue
      [ -n "$device" ] || continue
      lscp "$device" >/dev/null 2>&1 || continue
      ${body}
    done
  '';

  # Nothing is ever collected automatically: promotion to snapshot is what retains a checkpoint.
  promote = pkgs.writeShellApplication {
    name = "nas-checkpoint-promote";
    runtimeInputs = [
      pkgs.nilfs-utils
      pkgs.util-linux
      pkgs.gawk
      pkgs.findutils
    ];
    # The device argument needs patches/nilfs-utils-chcp-device-arg.patch; without it
    # chcp silently targets the first rw nilfs2 mount instead.
    text = forEachBranch ''
      lscp -r "$device" | awk '$4=="cp" {print $1}' | xargs -r -n1 chcp ss "$device" || true
    '';
  };

  # lscp prints local time; @GMT- names are UTC by convention, so convert explicitly.
  window = pkgs.writeShellApplication {
    name = "nas-checkpoint-window";
    runtimeInputs = [
      pkgs.nilfs-utils
      pkgs.util-linux
      pkgs.gawk
      pkgs.coreutils
    ];
    text = forEachBranch ''
      snapdir="$branch/${ccfg.snapshotDir}"
      mkdir -p "$snapdir"

      wanted=""
      while read -r cno cpdate cptime _rest; do
        [ -n "$cno" ] || continue
        epoch=$(date -d "$cpdate $cptime" +%s) || continue
        name=$(date -u -d "@$epoch" +@GMT-%Y.%m.%d-%H.%M.%S) || continue
        wanted="$wanted $name"
        if ! mountpoint -q "$snapdir/$name" 2>/dev/null; then
          mkdir -p "$snapdir/$name"
          mount -t nilfs2 -o "cp=$cno,ro" "$device" "$snapdir/$name" || rmdir "$snapdir/$name" || true
        fi
      done < <(lscp -s -r -n ${toString ccfg.window} "$device" | awk 'NR>1 {print $1, $2, $3}')

      for path in "$snapdir"/@GMT-*; do
        [ -d "$path" ] || continue
        case " $wanted " in
          *" $(basename "$path") "*) ;;
          *) umount "$path" 2>/dev/null && rmdir "$path" 2>/dev/null || true ;;
        esac
      done
    '';
  };

  at = pkgs.writeShellApplication {
    name = "nas-at";
    runtimeInputs = [
      pkgs.nilfs-utils
      pkgs.util-linux
      pkgs.gawk
      pkgs.coreutils
    ];
    text = ''
      usage() {
        echo "usage: nas-at '<YYYY-MM-DD HH:MM[:SS]>'   mount the array as it was" >&2
        echo "       nas-at --release <NAME>            unmount it" >&2
        echo "       nas-at --list                      show mounted views" >&2
        exit 2
      }

      case "''${1:-}" in
        --list)
          findmnt -rno TARGET -t nilfs2 | grep '@AT-' || echo "none mounted"
          exit 0
          ;;
        --release)
          [ $# -eq 2 ] || usage
          name=$2
          ${forEachBranch ''
            path="$branch/${ccfg.snapshotDir}/$name"
            [ -d "$path" ] && { umount "$path" 2>/dev/null || true; rmdir "$path" 2>/dev/null || true; }
          ''}
          echo "released $name"
          exit 0
          ;;
        "" ) usage ;;
      esac

      want=$(date -d "$1" +%s) || usage
      name="@AT-$(date -u -d "@$want" +%Y.%m.%d-%H.%M.%S)"
      found=0

      ${forEachBranch ''
        # Newest checkpoint at or before the requested time.
        cno=$(lscp "$device" | awk -v want="$want" '
          NR>1 && $1 ~ /^[0-9]+$/ {
            cmd = "date -d \"" $2 " " $3 "\" +%s"; cmd | getline epoch; close(cmd)
            if (epoch <= want && epoch > best) { best = epoch; keep = $1 }
          }
          END { if (keep != "") print keep }')

        if [ -z "$cno" ]; then
          echo "$branch: nothing retained at or before $1" >&2
        else
          target="$branch/${ccfg.snapshotDir}/$name"
          mkdir -p "$target"
          if mountpoint -q "$target" || mount -t nilfs2 -o "cp=$cno,ro" "$device" "$target"; then
            echo "$branch: checkpoint $cno"
            found=$((found + 1))
          else
            rmdir "$target" 2>/dev/null || true
          fi
        fi
      ''}

      [ "$found" -gt 0 ] || { echo "no branch had a checkpoint that old" >&2; exit 1; }
      echo "${cfg.dataRoot}/${ccfg.snapshotDir}/$name"
    '';
  };

  metrics = pkgs.writeShellApplication {
    name = "nas-checkpoint-metrics";
    runtimeInputs = [
      pkgs.nilfs-utils
      pkgs.util-linux
      pkgs.coreutils
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
          total=$(lscp "$device" | tail -n +2 | wc -l)
          snaps=$(lscp -s "$device" | tail -n +2 | wc -l)
          shown=$(find "$branch/${ccfg.snapshotDir}" -maxdepth 1 -name '@GMT-*' 2>/dev/null | wc -l)
          read -r used size <<<"$(df -B1 --output=used,size "$branch" | tail -1)"
          echo "nas_checkpoints{branch=\"$label\"} $total"
          echo "nas_checkpoint_snapshots{branch=\"$label\"} $snaps"
          echo "nas_checkpoints_exposed{branch=\"$label\"} $shown"
          echo "nas_branch_used_ratio{branch=\"$label\"} $(awk -v u="$used" -v s="$size" 'BEGIN{printf "%.6f", u/s}')"
          echo "nas_branch_size_bytes{branch=\"$label\"} $size"
        ''}
        echo "nas_metrics_timestamp_seconds $(date +%s)"
      } > "$tmp"
      mv "$tmp" ${ccfg.metricsFile}
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

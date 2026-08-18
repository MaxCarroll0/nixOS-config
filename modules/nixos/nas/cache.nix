# NAS cache warming: keeps btrfs metadata resident by walking the branches while disks spin.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas;
  scfg = cfg.storage;
  ccfg = cfg.cache;

  branches = lib.mapAttrsToList (name: _: "${scfg.diskRoot}/${name}") scfg.dataDisks;

  warmer = pkgs.writeShellApplication {
    name = "nas-metadata-warm";
    runtimeInputs = [
      pkgs.findutils
      pkgs.util-linux
      pkgs.coreutils
    ];
    text = ''
      start=$(date +%s)
      total=0
      for branch in ${lib.escapeShellArgs branches}; do
        mountpoint -q "$branch" || continue
        count=$(find "$branch" -xdev \
          -path '*/.snapshots' -prune -o \
          -path '*/.recycle' -prune -o \
          -print 2>/dev/null | wc -l)
        total=$((total + count))
      done
      elapsed=$(( $(date +%s) - start ))

      tmp=${ccfg.metricsFile}.tmp
      {
        echo '# HELP nas_metadata_warm_entries Directory entries stat-ed by the last warm pass.'
        echo '# TYPE nas_metadata_warm_entries gauge'
        echo "nas_metadata_warm_entries $total"
        echo '# HELP nas_metadata_warm_seconds Duration of the last warm pass.'
        echo '# TYPE nas_metadata_warm_seconds gauge'
        echo "nas_metadata_warm_seconds $elapsed"
        echo '# HELP nas_metadata_warm_timestamp_seconds Completion time of the last warm pass.'
        echo '# TYPE nas_metadata_warm_timestamp_seconds gauge'
        echo "nas_metadata_warm_timestamp_seconds $(date +%s)"
      } > "$tmp"
      mv "$tmp" ${ccfg.metricsFile}
    '';
  };
in

{
  options.local.nas.cache = {
    enable = lib.mkEnableOption "the metadata warmer";

    metricsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter-textfile/nas-cache.prom";
      description = "Textfile collector output for warm-pass statistics.";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 04:30:00";
      description = "When to warm, normally inside the mover and SnapRAID window while disks already spin.";
    };
  };

  config = lib.mkIf (cfg.enable && ccfg.enable) {
    systemd.services.nas-metadata-warm = {
      description = "Warm btrfs metadata into the read cache";
      after = [ "nas-snapraid-sync.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe warmer;
        Nice = 19;
        IOSchedulingClass = "idle";
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ (builtins.dirOf ccfg.metricsFile) ];
        ReadOnlyPaths = [ scfg.diskRoot ];
      };
    };

    systemd.timers.nas-metadata-warm = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = ccfg.schedule;
        Persistent = false;
        RandomizedDelaySec = "10m";
      };
    };
  };
}

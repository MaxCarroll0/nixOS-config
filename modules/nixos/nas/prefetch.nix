# Read-ahead: an open warms its folder, so a spun-up disk serves the rest of it from cache.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas;
  pcfg = cfg.prefetch;
  scfg = cfg.storage;

  branches = lib.attrNames scfg.dataDisks;

  mountUnit =
    name:
    "${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" "${scfg.diskRoot}/${name}")}.mount";

  warm = pkgs.writeShellApplication {
    name = "nas-prefetch";
    runtimeInputs = [
      pkgs.fatrace
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
    ];
    text = ''
      branch=$1
      cd "$branch"
      declare -A last_warm
      warmed_files=0
      warmed_bytes=0
      skipped=0

      publish() {
        tmp=${pcfg.metricsFile}.$$
        label=$(basename "$branch")
        {
          echo '# HELP nas_prefetch_files_total Files read ahead after a sibling was opened.'
          echo '# TYPE nas_prefetch_files_total counter'
          echo "nas_prefetch_files_total{branch=\"$label\"} $warmed_files"
          echo '# HELP nas_prefetch_bytes_total Bytes read ahead.'
          echo '# TYPE nas_prefetch_bytes_total counter'
          echo "nas_prefetch_bytes_total{branch=\"$label\"} $warmed_bytes"
          echo '# HELP nas_prefetch_skipped_total Opens ignored because the folder was still in cooldown.'
          echo '# TYPE nas_prefetch_skipped_total counter'
          echo "nas_prefetch_skipped_total{branch=\"$label\"} $skipped"
        } > "$tmp"
        mv "$tmp" ${pcfg.metricsFile}
      }

      trap 'publish; exit 0' EXIT TERM INT

      while IFS= read -r line; do
        case $line in *'"path":"'*) ;; *) continue ;; esac
        path=''${line#*'"path":"'}
        path=''${path%%'"'*}
        case $path in "$branch"/*) ;; *) continue ;; esac
        case $path in *"/${cfg.checkpoints.snapshotDir or "snapshots"}/"*) continue ;; esac

        comm=''${line#*'"comm":"'}
        comm=''${comm%%'"'*}
        case $comm in ${
          lib.concatStringsSep " | " (map (c: "${c}") pcfg.ignoreCommands)
        }) continue ;; esac

        dir=$(dirname "$path")
        now=$(date +%s)
        prev=''${last_warm[$dir]:-0}
        if [ $((now - prev)) -lt ${toString pcfg.cooldownSeconds} ]; then
          skipped=$((skipped + 1))
          if [ $((skipped % 50)) -eq 0 ]; then publish; fi
          continue
        fi
        last_warm[$dir]=$now

        budget=${toString pcfg.maxBytes}
        count=0
        while IFS= read -r sib; do
          if [ "$sib" = "$path" ]; then continue; fi
          if [ "$count" -ge ${toString pcfg.maxFiles} ]; then break; fi
          size=$(stat -c %s "$sib" 2>/dev/null || echo 0)
          if [ "$size" -le 0 ] || [ "$size" -gt "$budget" ]; then continue; fi
          if dd if="$sib" of=/dev/null bs=1M status=none 2>/dev/null; then
            count=$((count + 1))
            budget=$((budget - size))
            warmed_files=$((warmed_files + 1))
            warmed_bytes=$((warmed_bytes + size))
          fi
        done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)

        publish
      done < <(fatrace -c -f O -j -t -t)
    '';
  };
in

{
  options.local.nas.prefetch = {
    enable = lib.mkEnableOption "warming a folder into cache when one of its files is opened";

    cooldownSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "How long a folder is left alone after warming; this is what breaks the feedback loop.";
    };

    maxFiles = lib.mkOption {
      type = lib.types.ints.positive;
      default = 40;
      description = "Most siblings warmed per open.";
    };

    maxBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 512 * 1024 * 1024;
      description = "Byte budget per open, so one large folder cannot evict the whole cache.";
    };

    ignoreCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "snapraid"
        "nas-prefetch"
        "dd"
        "fatrace"
        "rsync"
        "nilfs_cleanerd"
      ];
      description = "Bulk readers whose opens must not trigger read-ahead; a scrub would otherwise warm the whole array.";
    };

    metricsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter-textfile/nas-prefetch.prom";
      description = "Textfile collector output for read-ahead counters.";
    };
  };

  config = lib.mkIf (cfg.enable && pcfg.enable) {
    systemd.services = lib.listToAttrs (
      map (name: {
        name = "nas-prefetch-${name}";
        value = {
          description = "Warm folders on ${name} when a file is opened";
          wantedBy = [
            (mountUnit name)
            "multi-user.target"
          ];
          partOf = [ (mountUnit name) ];
          after = [ (mountUnit name) ];
          unitConfig.ConditionPathIsMountPoint = "${scfg.diskRoot}/${name}";
          serviceConfig = {
            ExecStart = "${lib.getExe warm} ${scfg.diskRoot}/${name}";
            WorkingDirectory = "${scfg.diskRoot}/${name}";
            Restart = "on-failure";
            RestartSec = 30;
            Nice = 19;
            IOSchedulingClass = "idle";
            MemoryMax = "64M";
          };
        };
      }) branches
    );
  };
}

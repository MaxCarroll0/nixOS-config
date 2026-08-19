# Per-file version history: fatrace records writes, checkpoints hold the content.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas;
  vcfg = cfg.versions;
  scfg = cfg.storage;

  nilfsBranches = lib.filterAttrs (_: d: d.fsType == "nilfs2") scfg.dataDisks;

  db = "${vcfg.stateDir}/versions.db";
  eventsFor = name: "${vcfg.stateDir}/${name}.jsonl";
  offsetFor = name: "${vcfg.stateDir}/${name}.offset";

  ingest = pkgs.writeShellApplication {
    name = "nas-versions-ingest";
    runtimeInputs = [
      pkgs.jq
      pkgs.gawk
      pkgs.sqlite
      pkgs.nilfs-utils
      pkgs.util-linux
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      sqlite3 ${db} <<'SQL'
      CREATE TABLE IF NOT EXISTS versions (
        ino INTEGER NOT NULL, cno INTEGER NOT NULL, created INTEGER NOT NULL,
        PRIMARY KEY (ino, cno));
      CREATE TABLE IF NOT EXISTS inodes (
        branch TEXT NOT NULL, path TEXT NOT NULL, ino INTEGER NOT NULL, seen INTEGER NOT NULL,
        PRIMARY KEY (branch, path));
      CREATE INDEX IF NOT EXISTS inodes_ino ON inodes (ino);
      SQL

      # fatrace opens its output O_EXCL, never O_APPEND: read forward, rotate by restart.
      ingest_branch() {
        branch=$1
        events=$2
        offsetfile=$3
        unit=$4
        mountpoint -q "$branch" || return 0
        [ -s "$events" ] || return 0

        size=$(stat -c %s "$events")
        offset=$(cat "$offsetfile" 2>/dev/null || echo 0)
        [ "$size" -ge "$offset" ] || offset=0
        [ "$size" -gt "$offset" ] || return 0

        device=$(findmnt -no SOURCE "$branch" | head -1)
        lscp "$device" >/dev/null 2>&1 || return 0
        work=$(mktemp -d)
        # shellcheck disable=SC2064
        trap "rm -rf '$work'" RETURN

        tail -c "+$((offset + 1))" "$events" | head -c "$((size - offset))" > "$work/pending.jsonl"

        lscp "$device" | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1 "," $2 " " $3}' > "$work/cno.txt"
        cut -d, -f2 "$work/cno.txt" | date -f - +%s > "$work/epoch.txt"
        paste -d, <(cut -d, -f1 "$work/cno.txt") "$work/epoch.txt" > "$work/cps.csv"

        jq -r --arg root "$branch/" '
          select(.path | startswith($root))
          | [.inode, (.timestamp | floor), (.path[($root | length):])] | @csv
        ' "$work/pending.jsonl" > "$work/events.csv"

        sqlite3 ${db} <<SQL
      CREATE TEMP TABLE cps(cno INTEGER, epoch INTEGER);
      CREATE TEMP TABLE raw(ino INTEGER, ts INTEGER, path TEXT);
      .mode csv
      .import '$work/cps.csv' cps
      .import '$work/events.csv' raw
      BEGIN;
      INSERT INTO versions (ino, cno, created)
        SELECT DISTINCT r.ino,
          (SELECT c.cno FROM cps c WHERE c.epoch >= r.ts ORDER BY c.epoch LIMIT 1),
          (SELECT c.epoch FROM cps c WHERE c.epoch >= r.ts ORDER BY c.epoch LIMIT 1)
        FROM raw r
        WHERE (SELECT c.cno FROM cps c WHERE c.epoch >= r.ts ORDER BY c.epoch LIMIT 1) IS NOT NULL
        ON CONFLICT(ino, cno) DO NOTHING;
      INSERT INTO inodes (branch, path, ino, seen)
        SELECT '$branch', r.path, r.ino, MAX(r.ts) FROM raw r GROUP BY r.path
        ON CONFLICT(branch, path) DO UPDATE SET ino=excluded.ino, seen=excluded.seen;
      COMMIT;
      SQL

        printf '%s' "$size" > "$offsetfile"
        if [ "$size" -gt ${toString vcfg.rotateBytes} ]; then
          rm -f "$events"
          printf '0' > "$offsetfile"
          systemctl restart "$unit"
        fi
      }

      ${lib.concatMapStringsSep "\n" (name: ''
        ingest_branch ${scfg.diskRoot}/${name} ${eventsFor name} ${offsetFor name} nas-versions-watch-${name}.service
      '') (lib.attrNames nilfsBranches)}
    '';
  };

  versions = pkgs.writeShellApplication {
    name = "nas-versions";
    runtimeInputs = [
      pkgs.sqlite
      pkgs.nilfs-utils
      pkgs.util-linux
      pkgs.coreutils
    ];
    text = ''
      usage() {
        echo "usage: nas-versions list <path>" >&2
        echo "       nas-versions restore <path> --version N [--output PATH]" >&2
        echo "       nas-versions clean <path> --before YYYY-MM-DD" >&2
        exit 2
      }

      branches=( ${lib.escapeShellArgs (map (n: "${scfg.diskRoot}/${n}") (lib.attrNames nilfsBranches))} )

      # A pool path is served by mergerfs, so the owning branch is found by probing.
      resolve() {
        target=$(readlink -f "$1")
        branch=""
        case "$target" in
          ${cfg.dataRoot}/*)
            rel=''${target#"${cfg.dataRoot}"/}
            for b in "''${branches[@]}"; do
              [ -e "$b/$rel" ] && { branch=$b; break; }
            done
            ;;
          *)
            for b in "''${branches[@]}"; do
              case "$target" in "$b"/*) branch=$b; rel=''${target#"$b"/}; break ;; esac
            done
            ;;
        esac
        if [ -z "$branch" ] && [ -n "''${rel:-}" ]; then
          branch=$(sqlite3 -noheader ${db} "SELECT branch FROM inodes WHERE path='$rel' LIMIT 1;")
        fi
        [ -n "$branch" ] || { echo "not on a NILFS2 branch: $target" >&2; exit 1; }
        device=$(findmnt -no SOURCE "$branch" | head -1)
      }

      cmd=''${1:-}; shift || usage
      case "$cmd" in
        list)
          [ $# -ge 1 ] || usage
          resolve "$1"
          sqlite3 -noheader -separator '  ' ${db} \
            "SELECT (SELECT COUNT(*) FROM versions v2 WHERE v2.ino=i.ino AND v2.cno<=v.cno),
                    v.cno, datetime(v.created,'unixepoch')
             FROM versions v JOIN inodes i ON i.ino=v.ino
             WHERE i.branch='$branch' AND i.path='$rel' ORDER BY v.cno;" \
            | awk 'BEGIN{printf "%-8s %-10s %s\n","VERSION","CHECKPOINT","WHEN (UTC)"} {printf "%-8s %-10s %s %s\n",$1,$2,$3,$4}'
          ;;
        restore)
          [ $# -ge 3 ] || usage
          path="$1"; shift
          version=""; output=""
          while [ $# -gt 0 ]; do
            case "$1" in
              --version) version="$2"; shift 2 ;;
              --output) output="$2"; shift 2 ;;
              *) usage ;;
            esac
          done
          [ -n "$version" ] || usage
          resolve "$path"
          cno=$(sqlite3 -noheader ${db} \
            "SELECT v.cno FROM versions v JOIN inodes i ON i.ino=v.ino
             WHERE i.branch='$branch' AND i.path='$rel' ORDER BY v.cno
             LIMIT 1 OFFSET $((version - 1));")
          [ -n "$cno" ] || { echo "no version $version for $rel" >&2; exit 1; }
          tmp=$(mktemp -d /run/nas-restore.XXXXXX)
          trap 'umount "$tmp" 2>/dev/null || true; rmdir "$tmp" 2>/dev/null || true' EXIT
          mount -t nilfs2 -o "cp=$cno,ro" "$device" "$tmp"
          [ -f "$tmp/$rel" ] || { echo "$rel absent from checkpoint $cno" >&2; exit 1; }
          cp -a "$tmp/$rel" "''${output:-$target}"
          echo "restored version $version (checkpoint $cno) to ''${output:-$target}"
          ;;
        clean)
          echo "not implemented: removing versions is deliberate and needs the" >&2
          echo "checkpoint-exclusivity check described in docs/nas.md section 7.1" >&2
          exit 1
          ;;
        *) usage ;;
      esac
    '';
  };
in

{
  options.local.nas.versions = {
    enable = lib.mkEnableOption "per-file version history";

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nas-versions";
      description = "Where the version index and pending event files live; on the SSD.";
    };

    rotateBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 64 * 1024 * 1024;
      description = "Event file size at which the watcher is restarted onto a fresh file.";
    };

    ingestInterval = lib.mkOption {
      type = lib.types.str;
      default = "1m";
      description = "How often recorded writes are folded into the index.";
    };
  };

  config = lib.mkIf (cfg.enable && vcfg.enable && nilfsBranches != { }) {
    environment.systemPackages = [
      versions
      pkgs.fatrace
    ];

    systemd.tmpfiles.rules = [ "d ${vcfg.stateDir} 0750 root root - -" ];

    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (
        name: _:
        lib.nameValuePair "nas-versions-watch-${name}" {
          description = "Record writes on ${name} for version history";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStartPre = "${pkgs.coreutils}/bin/rm -f ${eventsFor name} ${offsetFor name}";
            ExecStart = "${pkgs.fatrace}/bin/fatrace -c -j -f W+D -t -t -o ${eventsFor name}";
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
        nas-versions-ingest = {
          description = "Fold recorded writes into the version index";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe ingest;
            Nice = 15;
            IOSchedulingClass = "idle";
          };
        };
      }
    ];

    systemd.timers.nas-versions-ingest = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "3m";
        OnUnitActiveSec = vcfg.ingestInterval;
        Persistent = false;
      };
    };
  };
}

# NAS streams: rsync daemon modules, each completed transfer ingested as a delta-store point.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas;
  scfg = cfg.storage;
  stateDir = "/var/lib/nas-streams";
  facts = import ../../../hosts/facts.nix;

  branchPath = st: "${scfg.diskRoot}/${st.branch}";

  streamDelta = pkgs.writeShellApplication {
    name = "stream-delta";
    runtimeInputs = [ (pkgs.python3.withPackages (ps: [ ps.zstandard ])) ];
    text = ''exec python3 ${./stream-delta.py} "$@"'';
  };

  point = pkgs.writeShellApplication {
    name = "nas-stream-point";
    runtimeInputs = [
      pkgs.nilfs-utils
      pkgs.util-linux
      pkgs.sqlite
      streamDelta
    ];
    text = ''
      [ "$RSYNC_EXIT_STATUS" = 0 ] || exit 0
      now=$(date +%s)
      cno=NULL
      id=$now
      if [ "$(findmnt -no FSTYPE "$1")" = nilfs2 ]; then
        cno=$(mkcp -s -p "$(findmnt -no SOURCE "$1")")
        id=$cno
      fi
      echo "$now" > ${stateDir}/"$RSYNC_MODULE_NAME".last
      sqlite3 ${cfg.streamPointsDb} \
        "CREATE TABLE IF NOT EXISTS points (stream TEXT, id TEXT, captured REAL, applied REAL, branch TEXT, cno INTEGER, stall_ms INTEGER, bytes INTEGER, PRIMARY KEY (stream, id));
         INSERT INTO points VALUES ('$RSYNC_MODULE_NAME', '$id', $now, $now, '$1', $cno, NULL, 0);"
      store=${cfg.streamDeltaDir}/"$RSYNC_MODULE_NAME"
      if [ -e "$store/ready" ]; then
        stream-delta --store "$store" ingest --mirror "$2" --captured "$now" --source "point:$id" \
          || logger -t nas-stream-delta "ingest of $RSYNC_MODULE_NAME point $id failed"
      fi
    '';
  };

  rsyncdConf =
    name: st:
    pkgs.writeText "nas-stream-${name}.conf" ''
      [${name}]
      path = ${branchPath st}/${st.root}
      use chroot = no
      read only = no
      write only = yes
      uid = root
      gid = root
      post-xfer exec = ${lib.getExe point} ${branchPath st} ${branchPath st}/${st.root}
    '';
in

{
  options.local.nas.streamPointsDb = lib.mkOption {
    type = lib.types.str;
    default = "${stateDir}/points.db";
    description = "Capture time to checkpoint for every stream point.";
  };

  options.local.nas.streamDeltaDir = lib.mkOption {
    type = lib.types.str;
    default = "${stateDir}/delta";
    description = "Per-stream delta stores; a store ingests only once its ready marker exists.";
  };

  options.local.nas.streams = lib.mkOption {
    default = { };
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            branch = lib.mkOption {
              type = lib.types.str;
              description = "Data disk the stream mirror lives on.";
            };
            root = lib.mkOption {
              type = lib.types.str;
              default = "backups/streams/${name}";
              description = "Stream tree, relative to the branch and the pool.";
            };
            port = lib.mkOption {
              type = lib.types.port;
              description = "Tailnet port the rsync daemon listens on.";
            };
            allowFrom = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Tailnet addresses allowed to push.";
            };
          };
        }
      )
    );
    description = "Continuously pushed backup streams.";
  };

  config = lib.mkIf (cfg.enable && cfg.streams != { }) {
    assertions = lib.mapAttrsToList (name: st: {
      assertion = scfg.dataDisks ? ${st.branch};
      message = "local.nas.streams.${name}.branch must name a data disk";
    }) cfg.streams;

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root - -"
      "d ${cfg.streamDeltaDir} 0700 root root - -"
    ];

    environment.systemPackages = [ streamDelta ];

    systemd.sockets = lib.mapAttrs' (
      name: st:
      lib.nameValuePair "nas-stream-${name}" {
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          ListenStream = "${facts.${config.networking.hostName}.tailscale}:${toString st.port}";
          Accept = true;
          FreeBind = true;
          MaxConnections = 1;
          IPAddressAllow = st.allowFrom;
          IPAddressDeny = "any";
        };
      }
    ) cfg.streams;

    systemd.timers."nas-stream-compact" = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "04:00";
        RandomizedDelaySec = "30min";
        Persistent = true;
      };
    };

    systemd.services =
      lib.mapAttrs' (
        name: st:
        lib.nameValuePair "nas-stream-${name}@" {
          unitConfig.ConditionPathIsMountPoint = branchPath st;
          serviceConfig = {
            ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${branchPath st}/${st.root}";
            ExecStart = "${pkgs.util-linux}/bin/flock ${cfg.nilfsWriteLock} ${lib.getExe pkgs.rsync} --daemon --config=${rsyncdConf name st}";
            StandardInput = "socket";
            StandardOutput = "inherit";
            RuntimeMaxSec = "10min";
            Nice = 5;
          };
        }
      ) cfg.streams
      // {
        nas-stream-compact = {
          script = ''
            for store in ${cfg.streamDeltaDir}/*/; do
              [ -e "$store/ready" ] || continue
              stream-delta --store "$store" compact --to-level 19 --limit 4
            done
          '';
          path = [ streamDelta ];
          serviceConfig = {
            Type = "oneshot";
            Nice = 19;
            CPUSchedulingPolicy = "idle";
            IOSchedulingClass = "idle";
          };
          restartIfChanged = false;
        };
      };

    networking.firewall.extraInputRules = lib.concatStrings (
      lib.mapAttrsToList (_: st: ''
        iifname "tailscale0" ip saddr { ${lib.concatStringsSep ", " st.allowFrom} } tcp dport ${toString st.port} accept
      '') cfg.streams
    );
  };
}

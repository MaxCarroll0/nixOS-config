# NAS streams: rsync daemon modules, each completed transfer ingested as a delta-store point.

{
  config,
  pkgs,
  lib,
  facts,
  ...
}:

let
  cfg = config.local.nas;
  scfg = cfg.storage;
  stateDir = "/var/lib/nas-streams";

  branchPath = st: "${scfg.diskRoot}/${st.branch}";
  mirrorDir = name: "${stateDir}/mirror/${name}";
  indexDir = name: "${cfg.streamIndexDir}/${name}";
  dataDir = st: "${branchPath st}/${st.data}";
  deltaArgs = name: st: "--index ${indexDir name} --data ${dataDir st}";

  point = pkgs.writeShellApplication {
    name = "nas-stream-point";
    runtimeInputs = [
      pkgs.util-linux
      pkgs.stream-delta
    ];
    text = ''
      [ "$RSYNC_EXIT_STATUS" = 0 ] || exit 0
      now=$(date +%s)
      if stream-delta --index "$1" --data "$2" ingest --mirror "$3" --captured "$now" --source "push:$now"; then
        echo "$now" > ${stateDir}/"$RSYNC_MODULE_NAME".last
      else
        logger -t nas-stream-delta "ingest of $RSYNC_MODULE_NAME at $now failed"
      fi
    '';
  };

  rsyncdConf =
    name: st:
    pkgs.writeText "nas-stream-${name}.conf" ''
      [${name}]
      path = ${mirrorDir name}
      use chroot = no
      read only = no
      write only = yes
      uid = root
      gid = root
      post-xfer exec = ${lib.getExe point} ${indexDir name} ${dataDir st} ${mirrorDir name}
    '';

  register = pkgs.writeShellApplication {
    name = "nas-stream-register";
    runtimeInputs = [ pkgs.sqlite ];
    text = ''
      sqlite3 ${cfg.streamPointsDb} \
        "CREATE TABLE IF NOT EXISTS delta_streams (stream TEXT PRIMARY KEY, index_dir TEXT NOT NULL, data_dir TEXT NOT NULL);
         DELETE FROM delta_streams;
         ${
           lib.concatStrings (
             lib.mapAttrsToList (
               name: st: "INSERT INTO delta_streams VALUES ('${name}', '${indexDir name}', '${dataDir st}');"
             ) cfg.streams
           )
         }"
    '';
  };
in

{
  options.local.nas.streamPointsDb = lib.mkOption {
    type = lib.types.str;
    default = "${stateDir}/points.db";
    description = "Stream registry shared with the time view.";
  };

  options.local.nas.streamIndexDir = lib.mkOption {
    type = lib.types.str;
    default = "${stateDir}/index";
    description = "Per-stream delta index caches, rebuildable from the packs.";
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
              description = "Data disk the delta packs live on.";
            };
            data = lib.mkOption {
              type = lib.types.str;
              default = "backups/delta/${name}";
              description = "Delta packs, relative to the branch.";
            };
            root = lib.mkOption {
              type = lib.types.str;
              default = "backups/streams/${name}";
              description = "Where the time view shows the stream, relative to the pool.";
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
      "d ${stateDir}/mirror 0700 root root - -"
      "d ${cfg.streamIndexDir} 0700 root root - -"
    ];

    environment.systemPackages = [ pkgs.stream-delta ];

    local.nas.checkpoints.historyless = lib.mkOptionDefault (
      lib.unique (
        lib.concatLists (
          lib.mapAttrsToList (_: st: [
            st.data
            st.root
          ]) cfg.streams
        )
      )
    );

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
            LogLevelMax = "notice";
            ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${mirrorDir name} ${dataDir st}";
            ExecStart = "${pkgs.util-linux}/bin/flock ${cfg.nilfsWriteLock} ${lib.getExe pkgs.rsync} --daemon --config=${rsyncdConf name st}";
            StandardInput = "socket";
            StandardOutput = "inherit";
            RuntimeMaxSec = "10min";
            Nice = 5;
          };
        }
      ) cfg.streams
      // {
        nas-stream-register = {
          wantedBy = [ "multi-user.target" ];
          before = [ "nas-at-view.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe register;
          };
        };

        nas-stream-compact = {
          script = lib.concatStrings (
            lib.mapAttrsToList (name: st: ''
              if mountpoint -q ${branchPath st}; then
                stream-delta ${deltaArgs name st} compact --to-level 19 --limit 4 --lock ${cfg.nilfsWriteLock}
              fi
            '') cfg.streams
          );
          path = [
            pkgs.stream-delta
            pkgs.util-linux
          ];
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

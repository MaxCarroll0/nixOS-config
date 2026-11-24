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
  mirrorRoot = name: "${stateDir}/mirror/${name}";
  mirrorDir = name: "${mirrorRoot name}/data";
  pushedFile = name: "${mirrorRoot name}/pushed";
  indexDir = name: "${cfg.streamIndexDir}/${name}";
  dataDir = st: "${branchPath st}/${st.data}";
  deltaArgs = name: st: "--index ${indexDir name} --data ${dataDir st}";
  pushUser = name: "nas-push-${name}";
  deltaUser = name: "nas-delta-${name}";
  streamLock = name: "/run/nas-streams/${name}.lock";

  pushed = pkgs.writeShellApplication {
    name = "nas-stream-pushed";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      [ "$RSYNC_EXIT_STATUS" = 0 ] || exit 0
      date +%s > "$1"
    '';
  };

  mirrorSetup = pkgs.writeShellApplication {
    name = "nas-stream-mirror-setup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.util-linux
      pkgs.e2fsprogs
    ];
    text = builtins.readFile ./stream-mirror-setup.sh;
  };

  ingest = pkgs.writeShellApplication {
    name = "nas-stream-ingest";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.util-linux
      pkgs.stream-delta
    ];
    text = builtins.readFile ./stream-ingest.sh;
  };

  rsyncdConf =
    name:
    pkgs.writeText "nas-stream-${name}.conf" ''
      [${name}]
      path = ${mirrorDir name}
      use chroot = no
      munge symlinks = yes
      read only = no
      write only = yes
      list = no
      numeric ids = yes
      reverse lookup = no
      incoming chmod = D750,F640
      timeout = 120
      post-xfer exec = ${lib.getExe pushed} ${pushedFile name}
    '';

  sandbox = {
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
  };

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
            mirrorSize = lib.mkOption {
              type = lib.types.str;
              default = "16G";
              description = "Size of the filesystem a push lands in, which caps what one pusher can store.";
            };
            dailyIngestLimit = lib.mkOption {
              type = lib.types.int;
              default = 8 * 1024 * 1024 * 1024;
              description = "Bytes the delta packs may grow per 24 hours before ingest is refused.";
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
      "d ${stateDir}/mirror 0711 root root - -"
      "d ${cfg.streamIndexDir} 0711 root root - -"
      "d /run/nas-streams 0755 root root - -"
      "f ${cfg.nilfsWriteLock} 0600 root root - -"
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (name: _: [
        "f ${streamLock name} 0640 root ${pushUser name} - -"
        "d ${indexDir name} 0700 ${deltaUser name} ${deltaUser name} - -"
      ]) cfg.streams
    );

    users.users = lib.mkMerge (
      lib.mapAttrsToList (name: _: {
        ${pushUser name} = {
          isSystemUser = true;
          group = pushUser name;
        };
        ${deltaUser name} = {
          isSystemUser = true;
          group = deltaUser name;
          extraGroups = [ (pushUser name) ];
        };
      }) cfg.streams
    );
    users.groups = lib.mkMerge (
      lib.mapAttrsToList (name: _: {
        ${pushUser name} = { };
        ${deltaUser name} = { };
      }) cfg.streams
    );

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

    systemd.paths = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "nas-stream-${name}-ingest" {
        wantedBy = [ "paths.target" ];
        requires = [ "nas-stream-${name}-mirror.service" ];
        after = [ "nas-stream-${name}-mirror.service" ];
        pathConfig.PathChanged = pushedFile name;
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
      lib.concatMapAttrs (name: st: {
        "nas-stream-${name}-mirror" = {
          wantedBy = [ "multi-user.target" ];
          after = [
            "local-fs.target"
            "systemd-tmpfiles-setup.service"
          ];
          before = [ "shutdown.target" ];
          conflicts = [ "shutdown.target" ];
          unitConfig.DefaultDependencies = false;
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${lib.getExe mirrorSetup} ${stateDir}/mirror/${name}.img ${mirrorRoot name} ${st.mirrorSize} ${pushUser name} ${pushUser name}";
            ExecStop = "${pkgs.util-linux}/bin/umount ${mirrorRoot name}";
          };
        };

        "nas-stream-${name}@" = {
          requires = [ "nas-stream-${name}-mirror.service" ];
          after = [ "nas-stream-${name}-mirror.service" ];
          serviceConfig = sandbox // {
            User = pushUser name;
            Group = pushUser name;
            LogLevelMax = "notice";
            ExecStart = "${pkgs.util-linux}/bin/flock ${streamLock name} ${lib.getExe pkgs.rsync} --daemon --config=${rsyncdConf name}";
            StandardInput = "socket";
            StandardOutput = "inherit";
            TemporaryFileSystem = [
              "/mnt:ro"
              "/var:ro"
            ];
            BindPaths = [ (mirrorRoot name) ];
            ReadWritePaths = [ "-${streamLock name}" ];
            NoNewPrivileges = true;
            CapabilityBoundingSet = "";
            MemoryDenyWriteExecute = true;
            ProcSubset = "pid";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            SystemCallFilter = [
              "@system-service"
              "~@privileged"
              "~@resources"
            ];
            SystemCallErrorNumber = "EPERM";
            IPAddressAllow = st.allowFrom;
            IPAddressDeny = "any";
            UMask = "0027";
            MemoryMax = "512M";
            TasksMax = 16;
            RuntimeMaxSec = "1h";
            Nice = 5;
          };
        };

        "nas-stream-${name}-ingest" = {
          startLimitIntervalSec = 0;
          unitConfig.ConditionPathIsMountPoint = branchPath st;
          requires = [ "nas-stream-${name}-mirror.service" ];
          after = [ "nas-stream-${name}-mirror.service" ];
          serviceConfig = sandbox // {
            Type = "oneshot";
            ExecStartPre = "+${pkgs.coreutils}/bin/mkdir -p ${dataDir st}";
            ExecStart = "${lib.getExe ingest} ${name} ${mirrorDir name} ${indexDir name} ${dataDir st} ${streamLock name} ${cfg.nilfsWriteLock} ${deltaUser name} ${toString st.dailyIngestLimit} ${stateDir}/${name}.last ${stateDir}/${name}.budget";
            ReadWritePaths = [
              stateDir
              "-${dataDir st}"
              "-${streamLock name}"
              "-${cfg.nilfsWriteLock}"
            ];
            CapabilityBoundingSet = [
              "CAP_SETUID"
              "CAP_SETGID"
              "CAP_CHOWN"
              "CAP_DAC_READ_SEARCH"
              "CAP_DAC_OVERRIDE"
              "CAP_FOWNER"
            ];
            PrivateNetwork = true;
            IPAddressDeny = "any";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            MemoryMax = "2G";
            TimeoutStartSec = "4h";
            Nice = 19;
            CPUSchedulingPolicy = "idle";
            IOSchedulingClass = "idle";
          };
        };
      }) cfg.streams
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
                find ${indexDir name} ${dataDir st} \( ! -user ${deltaUser name} -o ! -group ${deltaUser name} \) -exec chown -h ${deltaUser name}:${deltaUser name} {} +
                flock ${cfg.nilfsWriteLock} \
                  setpriv --reuid=${deltaUser name} --regid=${deltaUser name} --init-groups --no-new-privs --inh-caps=-all -- \
                  stream-delta ${deltaArgs name st} compact --to-level 19 --limit 4
              fi
            '') cfg.streams
          );
          path = [
            pkgs.coreutils
            pkgs.findutils
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

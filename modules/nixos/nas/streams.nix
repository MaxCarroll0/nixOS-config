# NAS streams: rsync daemon modules on a NILFS2 branch, one snapshot per completed transfer.

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

  point = pkgs.writeShellApplication {
    name = "nas-stream-point";
    runtimeInputs = [
      pkgs.nilfs-utils
      pkgs.util-linux
      pkgs.sqlite
    ];
    text = ''
      [ "$RSYNC_EXIT_STATUS" = 0 ] || exit 0
      cno=$(mkcp -s -p "$(findmnt -no SOURCE "$1")")
      now=$(date +%s)
      echo "$now" > ${stateDir}/"$RSYNC_MODULE_NAME".last
      sqlite3 ${cfg.streamPointsDb} \
        "CREATE TABLE IF NOT EXISTS points (stream TEXT, id TEXT, captured REAL, applied REAL, branch TEXT, cno INTEGER, stall_ms INTEGER, bytes INTEGER, PRIMARY KEY (stream, id));
         INSERT INTO points VALUES ('$RSYNC_MODULE_NAME', '$cno', $now, $now, '$1', $cno, NULL, 0);"
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
      post-xfer exec = ${lib.getExe point} ${branchPath st}
    '';
in

{
  options.local.nas.streamPointsDb = lib.mkOption {
    type = lib.types.str;
    default = "${stateDir}/points.db";
    description = "Capture time to checkpoint for every stream point.";
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
              description = "NILFS2 data disk the stream lives on.";
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
      assertion = (scfg.dataDisks.${st.branch}.fsType or null) == "nilfs2";
      message = "local.nas.streams.${name}.branch must name a nilfs2 data disk";
    }) cfg.streams;

    systemd.tmpfiles.rules = [ "d ${stateDir} 0755 root root - -" ];

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

    systemd.services = lib.mapAttrs' (
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
    ) cfg.streams;

    networking.firewall.extraInputRules = lib.concatStrings (
      lib.mapAttrsToList (_: st: ''
        iifname "tailscale0" ip saddr { ${lib.concatStringsSep ", " st.allowFrom} } tcp dport ${toString st.port} accept
      '') cfg.streams
    );
  };
}

# NAS streams: block deltas pushed over the tailnet, spooled on the SSD, applied as one NILFS2 snapshot each.

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

  mountUnit =
    branch:
    "${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" "${scfg.diskRoot}/${branch}")}.mount";

  stream = pkgs.writeShellApplication {
    name = "nas-stream";
    runtimeInputs = [
      pkgs.nilfs-utils
      pkgs.util-linux
    ];
    text = ''
      PYTHONPATH=${
        pkgs.linkFarm "blockdelta" [
          {
            name = "blockdelta.py";
            path = ../blockdelta.py;
          }
        ]
      } exec ${pkgs.python3}/bin/python3 ${./nas-stream.py} "$@"
    '';
  };

  argsFor = name: st: [
    "--name"
    name
    "--spool"
    "${stateDir}/spool/${name}"
    "--head"
    "${stateDir}/${name}.head"
    "--db"
    cfg.streamPointsDb
    "--branch"
    "${scfg.diskRoot}/${st.branch}"
    "--root"
    "${scfg.diskRoot}/${st.branch}/${st.root}"
    "--lock"
    cfg.nilfsWriteLock
    "--spool-max"
    (toString st.spoolMax)
    "--metrics"
    "/var/lib/node-exporter-textfile/nas-stream-${name}.prom"
  ];

  listen = st: "${facts.${config.networking.hostName}.tailscale}:${toString st.port}";
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
              description = "Tailnet port the receiver listens on.";
            };
            allowFrom = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Tailnet addresses allowed to push.";
            };
            spoolMax = lib.mkOption {
              type = lib.types.int;
              default = 8 * 1024 * 1024 * 1024;
              description = "Spool bytes above which pushes are refused.";
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

    environment.systemPackages = [ stream ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 root root - -"
      "d ${stateDir}/spool 0750 root root - -"
    ];

    systemd.sockets = lib.mapAttrs' (
      name: st:
      lib.nameValuePair "nas-stream-receive-${name}" {
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          ListenStream = listen st;
          Accept = true;
          FreeBind = true;
          MaxConnections = 4;
          IPAddressAllow = st.allowFrom;
          IPAddressDeny = "any";
        };
      }
    ) cfg.streams;

    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (
        name: st:
        lib.nameValuePair "nas-stream-receive-${name}@" {
          description = "Spool one ${name} stream delta";
          serviceConfig = {
            ExecStart = "${lib.getExe stream} ${lib.escapeShellArgs (argsFor name st)} receive";
            StandardInput = "socket";
            StandardOutput = "socket";
            StandardError = "journal";
            RuntimeMaxSec = "10min";
            Nice = 5;
          };
        }
      ) cfg.streams)

      (lib.mapAttrs' (
        name: st:
        lib.nameValuePair "nas-stream-apply-${name}" {
          description = "Apply spooled ${name} stream deltas to ${st.branch}";
          wantedBy = [ (mountUnit st.branch) ];
          partOf = [ (mountUnit st.branch) ];
          after = [ (mountUnit st.branch) ];
          serviceConfig = {
            ExecStart = "${lib.getExe stream} ${lib.escapeShellArgs (argsFor name st)} apply";
            Restart = "always";
            RestartSec = 30;
            Nice = 5;
          };
          unitConfig.ConditionPathIsMountPoint = "${scfg.diskRoot}/${st.branch}";
        }
      ) cfg.streams)
    ];

    networking.firewall.extraInputRules = lib.concatStrings (
      lib.mapAttrsToList (_: st: ''
        iifname "tailscale0" ip saddr { ${lib.concatStringsSep ", " st.allowFrom} } tcp dport ${toString st.port} accept
      '') cfg.streams
    );
  };
}

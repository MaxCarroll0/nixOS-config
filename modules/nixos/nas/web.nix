# NAS web tier: a dispatcher maps Tailscale identity to a per-user worker running as that user.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas;
  wcfg = cfg.web;

  socketDir = "/run/nas-web";
in

{
  options.local.nas.web = {
    enable = lib.mkEnableOption "the identity-mapped file browser";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8082;
      description = "Loopback port the dispatcher listens on; never bind this elsewhere.";
    };

    idleTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "How long an idle per-user worker lingers before exiting.";
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "96M";
      description = "Ceiling per worker, since one exists per active user.";
    };

    workerCommand = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.copyparty}/bin/copyparty -i 127.0.0.1 -p 0 -v %h::rw --no-crt -q";
      description = "Application run per account. %h is that account's home. It needs no auth or multi-tenancy: it only ever runs as one user and sees one home.";
    };
  };

  config = lib.mkIf (cfg.enable && wcfg.enable) {
    systemd.slices.nas-web = {
      description = "NAS per-user file browsers";
      sliceConfig.MemoryMax = "512M";
    };

    systemd.sockets."nas-web@" = {
      description = "Socket for %i's file browser";
      socketConfig = {
        ListenStream = "${socketDir}/%i.sock";
        SocketUser = "root";
        SocketMode = "0600";
        Accept = false;
      };
    };

    systemd.services."nas-web@" = {
      description = "File browser for %i";
      requires = [ "nas-web@%i.socket" ];
      after = [ "nas-web@%i.socket" ];
      serviceConfig = {
        User = "%i";
        Slice = "nas-web.slice";
        ExecStart = lib.replaceStrings [ "%h" ] [ "${cfg.dataRoot}/%i" ] wcfg.workerCommand;
        MemoryMax = wcfg.memoryMax;
        TimeoutStopSec = 10;
        RuntimeMaxSec = wcfg.idleTimeoutSeconds;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadOnlyPaths = [ "${cfg.dataRoot}/%i" ];
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    systemd.services.nas-web-dispatch = {
      description = "NAS web dispatcher";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./nas-web-dispatch.py} --listen 127.0.0.1 --port ${toString wcfg.port} --identity-map /etc/nas/identity-map --socket-dir ${socketDir}";
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "nas-web";
        RuntimeDirectoryMode = "0755";
        DynamicUser = false;
        User = "root";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadOnlyPaths = [ "/etc/nas" ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_UNIX"
        ];
        MemoryMax = "64M";
      };
    };
  };
}

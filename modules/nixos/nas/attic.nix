# Attic binary cache: a nix substituter for Max's own hosts, on the SSD, deliberately unprotected.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas;
  acfg = cfg.cache-server;
in

{
  options.local.nas.cache-server = {
    enable = lib.mkEnableOption "the Attic binary cache";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/cache";
      description = "Where Attic keeps its store; on the SSD, outside the array and outside SnapRAID.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Attic's listen port, reachable on the tailnet only.";
    };

    clientPort = lib.mkOption {
      type = lib.types.port;
      default = 18080;
      description = "Stable loopback port used by LAN-first cache clients.";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "cache";
      description = "Virtual host serving the cache.";
    };

    tlsCertificate = lib.mkOption {
      type = lib.types.path;
      default = ../../../keys/attic-server.crt;
      description = "Server certificate for the private cache name.";
    };

    interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "tailscale0" ];
      description = "LAN and tailnet interfaces on which the cache is reachable.";
    };

    garbageCollection = lib.mkOption {
      type = lib.types.str;
      default = "7d";
      description = "How long an unreferenced path survives before collection.";
    };
  };

  config = lib.mkIf (cfg.enable && acfg.enable) {
    # A stable account lets sops hand the initialized signing database to
    # atticd before the service starts.
    users.users.atticd = {
      isSystemUser = true;
      group = "atticd";
    };
    users.groups.atticd = { };

    services.atticd = {
      enable = true;
      environmentFile = config.sops.secrets."attic-server-token".path;
      settings = {
        listen = "127.0.0.1:${toString acfg.port}";
        allowed-hosts = [ acfg.hostname ];
        # Every client reaches this stable loopback port; peer-transport then
        # selects the Pi's LAN address or its tailnet address.
        api-endpoint = "https://${acfg.hostname}:${toString acfg.clientPort}/";
        require-proof-of-possession = false;
        database.url = "sqlite://${acfg.dataDir}/server.db?mode=rwc";
        storage = {
          type = "local";
          path = "${acfg.dataDir}/store";
        };
        chunking = {
          nar-size-threshold = 65536;
          min-size = 16384;
          avg-size = 65536;
          max-size = 262144;
        };
        garbage-collection = {
          interval = "12 hours";
          default-retention-period = acfg.garbageCollection;
        };
      };
    };

    sops.secrets = {
      "attic-server-token" = {
        sopsFile = ../../../secrets/attic-server-token.env;
        format = "binary";
      };
      "attic-tls-key" = {
        sopsFile = ../../../secrets/attic-tls-key.pem;
        format = "binary";
        owner = "nginx";
      };
      "attic-seed" = {
        sopsFile = ../../../secrets/attic-seed.db;
        format = "binary";
        owner = "atticd";
      };
    };

    systemd.services.atticd.serviceConfig.ExecStartPre = lib.getExe (
      pkgs.writeShellApplication {
        name = "attic-install-seed";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          if [ ! -e ${acfg.dataDir}/server.db ]; then
            install -m 0600 ${config.sops.secrets."attic-seed".path} ${acfg.dataDir}/server.db
          fi
        '';
      }
    );
    systemd.services.atticd.serviceConfig.ReadWritePaths = [ acfg.dataDir ];

    systemd.tmpfiles.rules = [
      "d ${acfg.dataDir} 0750 atticd atticd - -"
      "d ${acfg.dataDir}/store 0750 atticd atticd - -"
    ];

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      clientMaxBodySize = "4G";
      virtualHosts.${acfg.hostname} = {
        forceSSL = true;
        sslCertificate = acfg.tlsCertificate;
        sslCertificateKey = config.sops.secrets."attic-tls-key".path;
        locations."/".proxyPass = "http://127.0.0.1:${toString acfg.port}";
      };
    };

    networking.firewall.interfaces = lib.genAttrs acfg.interfaces (_: {
      allowedTCPPorts = [ 443 ];
    });
  };
}

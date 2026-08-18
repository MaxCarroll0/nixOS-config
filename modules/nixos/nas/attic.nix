# Attic binary cache: a nix substituter for Max's own hosts, on the SSD, deliberately unprotected.

{
  config,
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

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "cache";
      description = "Virtual host serving the cache.";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "tailscale0";
      description = "Interface the cache is exposed on; never the public one.";
    };

    garbageCollection = lib.mkOption {
      type = lib.types.str;
      default = "7d";
      description = "How long an unreferenced path survives before collection.";
    };
  };

  config = lib.mkIf (cfg.enable && acfg.enable) {
    services.atticd = {
      enable = true;
      environmentFile = config.sops.secrets."attic-server-token".path;
      settings = {
        listen = "127.0.0.1:${toString acfg.port}";
        allowed-hosts = [ acfg.hostname ];
        api-endpoint = "http://${acfg.hostname}/";
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

    sops.secrets."attic-server-token" = { };

    systemd.tmpfiles.rules = [
      "d ${acfg.dataDir} 0750 atticd atticd - -"
      "d ${acfg.dataDir}/store 0750 atticd atticd - -"
    ];

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      clientMaxBodySize = "4G";
      virtualHosts.${acfg.hostname}.locations."/".proxyPass = "http://127.0.0.1:${toString acfg.port}";
    };

    networking.firewall.interfaces.${acfg.interface}.allowedTCPPorts = [ 80 ];
  };
}

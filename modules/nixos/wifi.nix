# Declarative NetworkManager WiFi profiles, PSKs from sops.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.wifi;

  primary = lib.optional (cfg.ssid != null && cfg.pskSecret != null) {
    ssid = cfg.ssid;
    pskSecret = cfg.pskSecret;
    priority = 10;
  };

  networks = primary ++ (lib.imap0 (i: net: net // { priority = -i; }) cfg.fallbacks);

  preferFiveGhz = pkgs.writeShellApplication {
    name = "wifi-prefer-5ghz";
    runtimeInputs = [
      pkgs.jq
      pkgs.systemd
    ];
    text = builtins.readFile ./wifi-prefer-5ghz.sh;
  };

  keepalive = pkgs.writeShellApplication {
    name = "wifi-keepalive";
    runtimeInputs = [
      pkgs.iputils
      pkgs.iproute2
      pkgs.gawk
    ];
    text = builtins.readFile ./wifi-keepalive.sh;
  };

  envVar = secret: "WIFI_PSK_" + lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] secret);

  profileFor = net: {
    connection = {
      id = net.ssid;
      type = "wifi";
      autoconnect = true;
      autoconnect-retries = 0;
      autoconnect-priority = net.priority;
    };
    wifi = {
      ssid = net.ssid;
      mode = "infrastructure";
    };
    wifi-security = {
      auth-alg = "open";
      key-mgmt = "wpa-psk";
      psk = "$" + envVar net.pskSecret;
    };
    ipv4.method = "auto";
    ipv6.method = "auto";
  };
in

{
  options.local.wifi = {
    ssid = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    pskSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Name of a sops secret holding the plaintext WiFi PSK.";
    };

    preferFiveGhz = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Minimum 5 GHz signal in dBm at which a 2.4 GHz link roams to the same network's 5 GHz radio; null disables steering.";
    };

    keepalive = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "WiFi interface that pings its gateway every 200ms so iwlwifi never drops it for missed beacons; null disables it.";
    };

    fallbacks = lib.mkOption {
      default = [ ];
      description = "Lower-priority networks to autoconnect when the primary is absent.";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            ssid = lib.mkOption { type = lib.types.str; };
            pskSecret = lib.mkOption { type = lib.types.str; };
          };
        }
      );
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.keepalive != null) {
      systemd.services.wifi-keepalive = {
        description = "Ping keepalive to the WiFi gateway";
        wantedBy = [ "multi-user.target" ];
        after = [ "NetworkManager.service" ];
        environment.IFACE = cfg.keepalive;
        serviceConfig = {
          ExecStart = lib.getExe keepalive;
          Restart = "always";
          RestartSec = 5;
        };
      };
    })
    (lib.mkIf (cfg.preferFiveGhz != null) {
      systemd.services.wifi-prefer-5ghz = {
        description = "Roam a 2.4 GHz WiFi link to the same network's 5 GHz radio";
        after = [ "NetworkManager.service" ];
        environment.MIN_SIGNAL = toString cfg.preferFiveGhz;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe preferFiveGhz;
        };
      };

      systemd.timers.wifi-prefer-5ghz = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "30s";
          AccuracySec = "5s";
        };
      };
    })
    (lib.mkIf (networks != [ ]) {
      sops.secrets = lib.genAttrs (map (net: net.pskSecret) networks) (_: { });

      sops.templates."wifi-env".content = lib.concatMapStrings (
        net: "${envVar net.pskSecret}=${config.sops.placeholder.${net.pskSecret}}\n"
      ) networks;

      networking.networkmanager.ensureProfiles = {
        environmentFiles = [ config.sops.templates."wifi-env".path ];
        profiles = lib.listToAttrs (map (net: lib.nameValuePair net.ssid (profileFor net)) networks);
      };
    })
  ];
}

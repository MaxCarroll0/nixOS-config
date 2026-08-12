# Declarative NetworkManager WiFi profiles, PSKs from sops.

{
  config,
  lib,
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

  config = lib.mkIf (networks != [ ]) {
    sops.secrets = lib.genAttrs (map (net: net.pskSecret) networks) (_: { });

    sops.templates."wifi-env".content = lib.concatMapStrings (
      net: "${envVar net.pskSecret}=${config.sops.placeholder.${net.pskSecret}}\n"
    ) networks;

    networking.networkmanager.ensureProfiles = {
      environmentFiles = [ config.sops.templates."wifi-env".path ];
      profiles = lib.listToAttrs (map (net: lib.nameValuePair net.ssid (profileFor net)) networks);
    };
  };
}

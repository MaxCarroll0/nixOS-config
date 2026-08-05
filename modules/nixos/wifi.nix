# Declarative NetworkManager WiFi profile, PSK from sops.

{
  config,
  lib,
  ...
}:

let
  cfg = config.local.wifi;
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
  };

  config = lib.mkIf (cfg.ssid != null && cfg.pskSecret != null) {
    sops.secrets.${cfg.pskSecret} = { };

    sops.templates."wifi-env".content = ''
      WIFI_PSK=${config.sops.placeholder.${cfg.pskSecret}}
    '';

    networking.networkmanager.ensureProfiles = {
      environmentFiles = [ config.sops.templates."wifi-env".path ];

      profiles.${cfg.ssid} = {
        connection = {
          id = cfg.ssid;
          type = "wifi";
          autoconnect = true;
          # NetworkManager gives up on wifi after four tries by default, so an
          # AP reboot can leave a headless host down for good.
          autoconnect-retries = 0;
        };
        wifi = {
          ssid = cfg.ssid;
          mode = "infrastructure";
        };
        wifi-security = {
          auth-alg = "open";
          key-mgmt = "wpa-psk";
          psk = "$WIFI_PSK";
        };
        ipv4.method = "auto";
        ipv6.method = "auto";
      };
    };
  };
}

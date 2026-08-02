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

    systemd.services.wifi-profile = {
      description = "Write NetworkManager profile for ${cfg.ssid}";
      after = [ "sops-install-secrets.service" ];
      wants = [ "sops-install-secrets.service" ];
      before = [ "network-pre.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "5s";
      };
      script = ''
        psk=$(cat ${config.sops.secrets.${cfg.pskSecret}.path})
        install -d -m 0700 /etc/NetworkManager/system-connections
        cat > /etc/NetworkManager/system-connections/${cfg.ssid}.nmconnection <<EOF
        [connection]
        id=${cfg.ssid}
        type=wifi
        [wifi]
        ssid=${cfg.ssid}
        mode=infrastructure
        [wifi-security]
        auth-alg=open
        key-mgmt=wpa-psk
        psk=$psk
        [ipv4]
        method=auto
        [ipv6]
        method=auto
        EOF
        chmod 0600 /etc/NetworkManager/system-connections/${cfg.ssid}.nmconnection
        systemctl reload-or-restart NetworkManager
      '';
    };
  };
}

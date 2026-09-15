# Attic client using one stable loopback URL. peer-transport chooses the LAN
# address per connection and falls back to the Pi's Tailscale address.

{ config, pkgs, lib, ... }:

let
  cfg = config.local.atticClient;
  endpoint = "https://cache:${toString cfg.proxyPort}";
in
{
  options.local.atticClient = {
    enable = lib.mkEnableOption "the LAN-first Attic cache client";
    peer = lib.mkOption { type = lib.types.str; default = "pi"; };
    proxyPort = lib.mkOption { type = lib.types.port; default = 18080; };
    cache = lib.mkOption { type = lib.types.str; default = "main"; };
    publicKey = lib.mkOption {
      type = lib.types.str;
      description = "Attic cache signing public key.";
    };
    watchStore = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Upload completed local store additions asynchronously.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/attic-client-token";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."attic-client-token" = {
      sopsFile = ../../../secrets/attic-client-token;
      format = "binary";
    };

    local.peerTransport.forwards.attic = {
      inherit (cfg) peer;
      listenPort = cfg.proxyPort;
      targetPort = 443;
    };

    networking.hosts."127.0.0.1" = [ "cache" ];
    security.pki.certificates = [ (builtins.readFile ../../../keys/attic-ca.crt) ];

    nix.settings = {
      substituters = [ "${endpoint}/${cfg.cache}" ];
      trusted-substituters = [ "${endpoint}/${cfg.cache}" ];
      trusted-public-keys = [ cfg.publicKey ];
    };

    environment.systemPackages = [ pkgs.attic-client ];

    systemd.services.attic-watch-store = lib.mkIf cfg.watchStore {
      description = "Asynchronously upload completed store paths to Attic";
      wantedBy = [ "multi-user.target" ];
      after = [ "nix-daemon.service" "peer-forward-attic.service" ];
      requires = [ "peer-forward-attic.service" ];
      serviceConfig = {
        User = "root";
        Environment = "ATTIC_CONFIG=/run/attic/client.toml";
        ExecStartPre = pkgs.writeShellScript "attic-client-config" ''
          install -d -m 0700 /run/attic
          token=$(cat ${lib.escapeShellArg cfg.tokenFile})
          cat > /run/attic/client.toml <<EOF
          [servers.lan]
          endpoint = "${endpoint}"
          token = "$token"
          EOF
          chmod 0600 /run/attic/client.toml
        '';
        ExecStart = "${pkgs.attic-client}/bin/attic watch-store --jobs 1 lan:${cfg.cache}";
        Restart = "always";
        RestartSec = 10;
        Nice = 19;
        IOSchedulingClass = "idle";
        CPUWeight = 10;
        IOWeight = 10;
      };
    };
  };
}

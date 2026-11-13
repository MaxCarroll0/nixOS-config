# Attic client using one stable loopback URL. peer-transport chooses the LAN
# address per connection and falls back to the Pi's Tailscale address.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas.attic.client;
  endpoint = "https://cache:${toString cfg.proxyPort}";
  stateDir = "/var/lib/attic-upload";

  queueHook = pkgs.writeShellApplication {
    name = "attic-queue-paths";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
    ];
    text = ''
      install -d -m 0700 ${stateDir}
      (
        flock 9
        for path in $OUT_PATHS; do
          printf '%s\n' "$path"
        done >> ${stateDir}/queue
      ) 9> ${stateDir}/queue.lock
    '';
  };

  writeConfig = pkgs.writeShellApplication {
    name = "attic-client-config";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      install -d -m 0700 /run/attic /run/attic/attic
      token=$(cat ${lib.escapeShellArg cfg.tokenFile})
      cat > /run/attic/attic/config.toml <<EOF
      [servers.lan]
      endpoint = "${endpoint}"
      token = "$token"
      EOF
      chmod 0600 /run/attic/attic/config.toml
    '';
  };

  uploadQueued = pkgs.writeShellApplication {
    name = "attic-upload-queued";
    runtimeInputs = with pkgs; [
      attic-client
      coreutils
      gawk
      util-linux
    ];
    text = builtins.replaceStrings [ "@stateDir@" "@cache@" "@maxAttempts@" ] [ stateDir cfg.cache (toString cfg.maxAttempts) ] (builtins.readFile ./attic-upload-queued.sh);
  };
in
{
  options.local.nas.attic.client = {
    enable = lib.mkEnableOption "the LAN-first Attic cache client";
    peer = lib.mkOption {
      type = lib.types.str;
      default = "pi";
    };
    proxyPort = lib.mkOption {
      type = lib.types.port;
      default = 18080;
    };
    cache = lib.mkOption {
      type = lib.types.str;
      default = "main";
    };
    publicKey = lib.mkOption {
      type = lib.types.str;
      description = "Attic cache signing public key.";
    };
    watchStore = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Queue completed builds and upload them after the requester has received the result.";
    };
    maxAttempts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Failed uploads of one path, with the server reachable, before it is moved to the failed list.";
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
      post-build-hook = lib.mkIf cfg.watchStore "${queueHook}/bin/attic-queue-paths";
    };

    environment.systemPackages = [ pkgs.attic-client ];
    systemd.tmpfiles.rules = lib.optional cfg.watchStore "d ${stateDir} 0700 root root - -";

    systemd.services.attic-upload = lib.mkIf cfg.watchStore {
      description = "Upload queued Nix build results to Attic";
      after = [ "peer-forward-attic.service" ];
      requires = [ "peer-forward-attic.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Environment = "XDG_CONFIG_HOME=/run/attic";
        ExecStartPre = "${writeConfig}/bin/attic-client-config";
        ExecStart = "${uploadQueued}/bin/attic-upload-queued";
        Nice = 19;
        IOSchedulingClass = "idle";
        CPUWeight = 10;
        IOWeight = 10;
      };
    };

    systemd.timers.attic-upload = lib.mkIf cfg.watchStore {
      description = "Periodically upload queued Nix build results";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "2min";
        RandomizedDelaySec = "30s";
        Unit = "attic-upload.service";
      };
    };
  };
}

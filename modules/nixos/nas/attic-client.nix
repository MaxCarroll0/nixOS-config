# Attic client using one stable loopback URL. peer-transport chooses the LAN
# address per connection and falls back to the Pi's Tailscale address.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.atticClient;
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
      install -d -m 0700 /run/attic
      token=$(cat ${lib.escapeShellArg cfg.tokenFile})
      cat > /run/attic/client.toml <<EOF
      [servers.lan]
      endpoint = "${endpoint}"
      token = "$token"
      EOF
      chmod 0600 /run/attic/client.toml
    '';
  };

  uploadQueued = pkgs.writeShellApplication {
    name = "attic-upload-queued";
    runtimeInputs = with pkgs; [
      attic-client
      coreutils
      util-linux
    ];
    text = ''
      install -d -m 0700 ${stateDir}

      # Recover a batch if the previous service invocation was interrupted,
      # then detach the current queue without holding the build hook's lock
      # during the potentially long network upload.
      (
        flock 9
        if [ -s ${stateDir}/pending ]; then
          cat ${stateDir}/pending >> ${stateDir}/queue
          rm -f ${stateDir}/pending
        fi
        if [ -s ${stateDir}/queue ]; then
          mv ${stateDir}/queue ${stateDir}/pending
        fi
      ) 9> ${stateDir}/queue.lock

      if [ ! -s ${stateDir}/pending ]; then
        exit 0
      fi

      if attic push --stdin --jobs 1 lan:${cfg.cache} < ${stateDir}/pending; then
        rm -f ${stateDir}/pending
      else
        # Attic pushes are idempotent. Requeue the whole batch so a partial
        # upload or network change is safely retried on the next timer run.
        (
          flock 9
          cat ${stateDir}/pending >> ${stateDir}/queue
          rm -f ${stateDir}/pending
        ) 9> ${stateDir}/queue.lock
        exit 1
      fi
    '';
  };
in
{
  options.local.atticClient = {
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
        Environment = "ATTIC_CONFIG=/run/attic/client.toml";
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

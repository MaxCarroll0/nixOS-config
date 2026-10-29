# Tailnet HTTP endpoint that wakes a peer and relays its own endpoint, or runs a local command.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.wakeEndpoint;
  facts = import ../../hosts/facts.nix;
  peerUrl = "http://${facts.${cfg.peer}.tailscale}:${toString cfg.port}/";
in

{
  options.local.wakeEndpoint = {
    peer = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "local.wake.peers entry a visit wakes, whose own endpoint is then relayed.";
    };

    command = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Program run on each visit; its stdout becomes the reply.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9099;
      description = "Port on this host's tailnet address, and on the peer's.";
    };

    peerTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 150;
      description = "How long to wait for the woken peer's endpoint to answer.";
    };
  };

  config = lib.mkIf (cfg.peer != null || cfg.command != null) {
    systemd.sockets.wake-endpoint = {
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "${facts.${config.networking.hostName}.tailscale}:${toString cfg.port}";
        FreeBind = true;
        Accept = true;
        MaxConnections = 4;
        PollLimitIntervalSec = "1min";
        PollLimitBurst = 10;
      };
    };

    systemd.services."wake-endpoint@" = {
      path = [
        pkgs.curl
        pkgs.coreutils
      ];
      serviceConfig = {
        DynamicUser = true;
        StandardInput = "socket";
        StandardOutput = "socket";
        RuntimeMaxSec = cfg.peerTimeoutSeconds + 30;
      };
      script = ''
        read -r -t 5 _ path _ || exit 0
        while read -r -t 5 header && [ "''${header%$'\r'}" != "" ]; do :; done

        respond() {
          printf 'HTTP/1.0 %s\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s\n' "$1" "$2"
        }

        if [ "$path" != / ]; then
          respond "404 Not Found" ""
          exit 0
        fi

        status="200 OK"
        body=""
        ${lib.optionalString (cfg.peer != null) ''
          if ${config.local.wake.package}/bin/wake-peer --send-only ${lib.escapeShellArg cfg.peer} >&2; then
            deadline=$(( $(date +%s) + ${toString cfg.peerTimeoutSeconds} ))
            until reply=$(curl -fsS -m 10 ${peerUrl} 2>/dev/null); do
              if [ "$(date +%s)" -ge "$deadline" ]; then
                reply="wake sent, but no answer within ${toString cfg.peerTimeoutSeconds}s"
                status="504 Gateway Timeout"
                break
              fi
              sleep 3
            done
            body="${cfg.peer}: $reply"
          else
            status="500 Internal Server Error"
            body="${cfg.peer}: sending the wake failed"
          fi
        ''}
        ${lib.optionalString (cfg.command != null) ''
          if ! body=$(${cfg.command} 2>&1); then
            status="500 Internal Server Error"
          fi
        ''}
        respond "$status" "$body"
      '';
    };

    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];
  };
}

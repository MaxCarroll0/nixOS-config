# Tailnet HTTP page that wakes one peer on visit, for users with no shell here.

{
  config,
  lib,
  ...
}:

let
  cfg = config.local.wakeEndpoint;
  facts = import ../../hosts/facts.nix;
in

{
  options.local.wakeEndpoint = {
    peer = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "local.wake.peers entry a visit wakes.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9099;
      description = "Port on this host's tailnet address.";
    };
  };

  config = lib.mkIf (cfg.peer != null) {
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
      serviceConfig = {
        DynamicUser = true;
        StandardInput = "socket";
        StandardOutput = "socket";
        RuntimeMaxSec = "15s";
      };
      script = ''
        read -r -t 5 _ path _ || exit 0
        while read -r -t 5 header && [ "''${header%$'\r'}" != "" ]; do :; done

        respond() {
          printf 'HTTP/1.0 %s\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s\n' "$1" "$2"
        }

        if [ "$path" != / ]; then
          respond "404 Not Found" ""
          exit 0
        fi

        if ${config.local.wake.package}/bin/wake-peer --send-only ${lib.escapeShellArg cfg.peer} >&2; then
          respond "200 OK" '<!doctype html><title>Wake ${cfg.peer}</title><meta name="viewport" content="width=device-width"><body style="font:1.2em sans-serif;margin:2em">Wake sent to ${cfg.peer}. It is reachable in about a minute.</body>'
        else
          respond "500 Internal Server Error" '<!doctype html><title>Wake ${cfg.peer}</title><body style="font:1.2em sans-serif;margin:2em">Sending the wake failed.</body>'
        fi
      '';
    };

    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];
  };
}

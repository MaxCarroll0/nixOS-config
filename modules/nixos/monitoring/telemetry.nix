# Local journal access over HTTP; logs are never shipped off the host.

{
  config,
  lib,
  ...
}:

let
  cfg = config.local.monitoring.telemetry;
in

{
  options.local.monitoring.telemetry = {
    journalGateway = {
      enable = lib.mkEnableOption "systemd-journal-gatewayd on the tailnet";

      port = lib.mkOption {
        type = lib.types.port;
        default = 19531;
        description = "Port the journal gateway listens on.";
      };
    };

    journalRetention = lib.mkOption {
      type = lib.types.str;
      default = "30day";
      description = "How long journald keeps logs on this host.";
    };

    serverAddress = lib.mkOption {
      type = lib.types.str;
      default = "100.117.13.66";
      description = "Tailnet address of the metrics server.";
    };
  };

  config = lib.mkIf cfg.journalGateway.enable {
    systemd.additionalUpstreamSystemUnits = [
      "systemd-journal-gatewayd.socket"
      "systemd-journal-gatewayd.service"
    ];

    systemd.sockets.systemd-journal-gatewayd = {
      wantedBy = [ "sockets.target" ];
      listenStreams = lib.mkForce [
        ""
        (toString cfg.journalGateway.port)
      ];
    };

    services.journald.extraConfig = ''
      MaxRetentionSec=${cfg.journalRetention}
    '';

    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.journalGateway.port ];
  };
}

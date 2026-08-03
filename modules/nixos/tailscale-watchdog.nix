# Reboot a headless host if tailscale never gets an address, up to a limit.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.server.tailscaleWatchdog;
in

{
  options.local.server.tailscaleWatchdog = {
    enable = lib.mkEnableOption "rebooting when tailscale has no address";

    maxReboots = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = "Give up after this many reboots; a reboot cannot fix a bad key.";
    };

    rebootCommand = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.systemd}/bin/systemctl --no-block reboot";
      description = "Overridden by the test harness.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.tailscale-watchdog = {
      description = "Reboot if tailscale has no address";
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "tailscale-watchdog";
      };
      script = ''
        if ${pkgs.iproute2}/bin/ip -4 addr show tailscale0 2>/dev/null | grep -q inet; then
          rm -f "$STATE_DIRECTORY/attempts"
          exit 0
        fi

        attempts=$(cat "$STATE_DIRECTORY/attempts" 2>/dev/null || echo 0)
        if [ "$attempts" -ge ${toString cfg.maxReboots} ]; then
          echo "tailscale still down after $attempts reboots, giving up" >&2
          exit 0
        fi

        echo $((attempts + 1)) > "$STATE_DIRECTORY/attempts"
        ${cfg.rebootCommand}
      '';
    };

    systemd.timers.tailscale-watchdog = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "5min";
        Unit = "tailscale-watchdog.service";
      };
    };
  };
}

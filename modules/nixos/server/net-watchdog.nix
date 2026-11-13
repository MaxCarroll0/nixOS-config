# Keep a headless host on the network: bounce the connection, then reboot.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.server.netWatchdog;

  gatewayUp = pkgs.writeShellApplication {
    name = "gateway-up";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      iproute2
      iputils
    ];
    text = ''
      gateway=$(ip -4 route show default | awk '{ print $3; exit }')
      [ -n "$gateway" ] || exit 1
      ping -c 1 -W 2 "$gateway" >/dev/null 2>&1
    '';
  };
in

{
  options.local.server.netWatchdog = {
    enable = lib.mkEnableOption "bouncing the connection, then rebooting, when the LAN goes away";

    reconnectProfile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = config.local.wifi.ssid or null;
      description = "NetworkManager profile to bring back up.";
    };

    bounceAfter = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Consecutive failed checks before bouncing; NetworkManager reconnects on its own in under a minute.";
    };

    rebootAfter = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Consecutive failed checks before rebooting.";
    };

    maxReboots = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = "Give up after this many; a reboot cannot fix a dead AP.";
    };

    rebootCommand = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.systemd}/bin/systemctl --no-block reboot";
      description = "Overridden by the test harness.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.bounceAfter < cfg.rebootAfter;
        message = "local.server.netWatchdog must bounce the connection before it reboots.";
      }
    ];

    environment.systemPackages = [ gatewayUp ];

    systemd.services.net-watchdog = {
      description = "Recover the network, escalating to a reboot";
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "net-watchdog";
      };
      script = ''
        if ${lib.getExe gatewayUp}; then
          rm -f "$STATE_DIRECTORY/attempts" "$STATE_DIRECTORY/reboots"
          exit 0
        fi

        attempts=$(cat "$STATE_DIRECTORY/attempts" 2>/dev/null || echo 0)
        attempts=$((attempts + 1))
        echo "$attempts" > "$STATE_DIRECTORY/attempts"

        if [ "$attempts" -ge ${toString cfg.rebootAfter} ]; then
          reboots=$(cat "$STATE_DIRECTORY/reboots" 2>/dev/null || echo 0)
          if [ "$reboots" -ge ${toString cfg.maxReboots} ]; then
            echo "still down after $reboots reboots, giving up" >&2
            exit 0
          fi
          echo $((reboots + 1)) > "$STATE_DIRECTORY/reboots"
          echo "down for $attempts checks, rebooting" >&2
          ${cfg.rebootCommand}
          exit 0
        fi

        if [ "$attempts" -ge ${toString cfg.bounceAfter} ]; then
          ${
            if cfg.reconnectProfile == null then
              ''echo "down for $attempts checks, no profile to bounce" >&2''
            else
              ''
                echo "down for $attempts checks, bouncing ${cfg.reconnectProfile}" >&2
                ${pkgs.networkmanager}/bin/nmcli connection up ${lib.escapeShellArg cfg.reconnectProfile} || true
              ''
          }
        fi
      '';
    };

    systemd.timers.net-watchdog = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "1min";
        Unit = "net-watchdog.service";
      };
    };
  };
}

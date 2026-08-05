# Keep a headless host on the network: reconnect, restart NetworkManager, reboot.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.server.netWatchdog;

  netHealthy = pkgs.writeShellApplication {
    name = "net-healthy";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnugrep
      iproute2
      iputils
    ];
    text = ''
      ip -4 addr show tailscale0 2>/dev/null | grep -q inet || exit 1

      gateway=$(ip -4 route show default | awk '{ print $3; exit }')
      if [ -n "$gateway" ] && ping -c 1 -W 1 "$gateway" >/dev/null 2>&1; then
        exit 0
      fi

      ${lib.concatMapStringsSep "\n" (peer: ''
        if ${lib.getExe config.services.tailscale.package} ping --timeout=2s --c=1 ${lib.escapeShellArg peer} >/dev/null 2>&1; then
          exit 0
        fi
      '') cfg.peers}

      exit 1
    '';
  };
in

{
  options.local.server.netWatchdog = {
    enable = lib.mkEnableOption "escalating recovery when the network goes away";

    peers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Tailnet names that prove reachability when the gateway will not answer.";
    };

    reconnectProfile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = config.local.wifi.ssid or null;
      description = "NetworkManager profile to bring up before restarting the daemon.";
    };

    maxReboots = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = "Give up after this many; a reboot cannot fix a bad key or a dead AP.";
    };

    rebootCommand = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.systemd}/bin/systemctl --no-block reboot";
      description = "Overridden by the test harness.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = netHealthy;
      readOnly = true;
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ netHealthy ];

    systemd.services.net-watchdog = {
      description = "Recover the network, escalating to a reboot";
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "net-watchdog";
      };
      script = ''
        if ${lib.getExe netHealthy}; then
          rm -f "$STATE_DIRECTORY/attempts" "$STATE_DIRECTORY/reboots"
          exit 0
        fi

        attempts=$(cat "$STATE_DIRECTORY/attempts" 2>/dev/null || echo 0)
        attempts=$((attempts + 1))
        echo "$attempts" > "$STATE_DIRECTORY/attempts"

        case "$attempts" in
          1)
            ${lib.optionalString (cfg.reconnectProfile != null) ''
              echo "network down, reconnecting ${cfg.reconnectProfile}" >&2
              ${pkgs.networkmanager}/bin/nmcli connection up ${lib.escapeShellArg cfg.reconnectProfile} || true
            ''}
            ;;
          2)
            echo "still down, restarting NetworkManager" >&2
            ${pkgs.systemd}/bin/systemctl restart NetworkManager.service || true
            ;;
          *)
            # A reboot returns to the same generation, so it cannot fix a bad
            # switch. Let rollback-guard finish deciding first.
            if [ "$(${pkgs.systemd}/bin/systemctl show -p ActiveState --value rollback-guard.service 2>/dev/null)" = activating ]; then
              echo "rollback-guard still deciding, deferring reboot" >&2
              exit 0
            fi

            reboots=$(cat "$STATE_DIRECTORY/reboots" 2>/dev/null || echo 0)
            if [ "$reboots" -ge ${toString cfg.maxReboots} ]; then
              echo "still down after $reboots reboots, giving up" >&2
              exit 0
            fi
            echo $((reboots + 1)) > "$STATE_DIRECTORY/reboots"
            echo "still down, rebooting" >&2
            ${cfg.rebootCommand}
            ;;
        esac
      '';
    };

    systemd.timers.net-watchdog = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "2min";
        Unit = "net-watchdog.service";
      };
    };
  };
}

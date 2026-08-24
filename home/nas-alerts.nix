# Desktop notifications for NAS alerts, including the case Grafana cannot report: the pi being down.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nasAlerts;
  state = "%t/nas-alerts";

  notifier = pkgs.writeShellApplication {
    name = "nas-alert-notify";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.libnotify
      pkgs.coreutils
    ];
    text = ''
      state=''${RUNTIME_DIRECTORY:-/tmp}/last
      previous=$(cat "$state" 2>/dev/null || echo "")

      # An unreachable pi is the alert Grafana can never send, because Grafana is on the pi.
      if ! curl -fsS --max-time ${toString cfg.timeoutSeconds} \
             "${cfg.url}/api/health" -o /dev/null 2>/dev/null; then
        current="unreachable"
        if [ "$previous" != "$current" ]; then
          notify-send -u critical -a NAS "NAS unreachable" \
            "${cfg.url} is not responding. The pi may be down; the array is not being versioned or synced."
        fi
        printf '%s' "$current" > "$state"
        exit 0
      fi

      firing=$(curl -fsS --max-time ${toString cfg.timeoutSeconds} \
        "${cfg.url}/api/alertmanager/grafana/api/v2/alerts" 2>/dev/null \
        | jq -r '[.[] | select(.status.state == "active")
                      | .labels.alertname] | sort | unique | join(", ")' 2>/dev/null || echo "")

      current=''${firing:-none}
      if [ "$current" != "$previous" ]; then
        if [ "$current" = "none" ]; then
          [ -n "$previous" ] && [ "$previous" != "none" ] \
            && notify-send -u normal -a NAS "NAS alerts cleared" "Nothing is firing."
        else
          notify-send -u critical -a NAS "NAS alert" "$current"
        fi
      fi
      printf '%s' "$current" > "$state"
    '';
  };
in

{
  options.local.nasAlerts = {
    enable = lib.mkEnableOption "desktop notifications for NAS and pi alerts";

    url = lib.mkOption {
      type = lib.types.str;
      default = "http://observatory";
      description = "Grafana base URL; identity comes from the tailnet, so no credentials are needed.";
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Seconds between checks.";
    };

    timeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Per-request timeout; exceeding it counts as unreachable.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.nas-alert-notify = {
      Unit.Description = "Notify about NAS alerts and pi reachability";
      Service = {
        Type = "oneshot";
        ExecStart = lib.getExe notifier;
        RuntimeDirectory = "nas-alerts";
        RuntimeDirectoryPreserve = "yes";
      };
    };

    systemd.user.timers.nas-alert-notify = {
      Unit.Description = "Check NAS alerts periodically";
      Install.WantedBy = [ "timers.target" ];
      Timer = {
        OnStartupSec = "2m";
        OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
        AccuracySec = "30s";
      };
    };
  };
}

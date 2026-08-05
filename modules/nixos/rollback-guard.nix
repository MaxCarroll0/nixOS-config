# Roll back a switch that leaves the host unreachable over the tailnet.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.rollbackGuard;

  # An address on tailscale0 survives a wifi outage, so it alone cannot tell a
  # working generation from one that just cut the host off.
  healthy =
    if (config.local.server.netWatchdog.enable or false) then
      lib.getExe config.local.server.netWatchdog.package
    else
      "${pkgs.iproute2}/bin/ip -4 addr show tailscale0 2>/dev/null | grep -q inet "
      + "&& ${pkgs.systemd}/bin/systemctl is-active --quiet NetworkManager.service";
in

{
  options.local.rollbackGuard = {
    enable = lib.mkEnableOption "reverting a generation that comes up with no network";

    graceSeconds = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "How long connectivity may take to appear before rolling back.";
    };

    settleSeconds = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = "Wait for the switch to finish restarting units before the grace period starts.";
    };

    maxRollbacks = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Stop after this many, so a network outage cannot walk the host back through every generation.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.rollback-guard = {
      description = "Roll back if this generation has no network";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "tailscaled.service"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "rollback-guard";
        TimeoutStartSec = cfg.settleSeconds + cfg.graceSeconds + 120;
      };

      script = ''
        booted=$(readlink -f /run/current-system)

        for _ in $(seq 1 ${toString cfg.settleSeconds}); do
          state=$(${pkgs.systemd}/bin/systemctl is-system-running 2>/dev/null || true)
          case "$state" in
            starting|initializing|"") sleep 1 ;;
            *) break ;;
          esac
        done

        for _ in $(seq 1 ${toString cfg.graceSeconds}); do
          if ${healthy}; then
            echo "network is up"
            rm -f "$STATE_DIRECTORY/count"
            echo "$booted" > "$STATE_DIRECTORY/good"
            exit 0
          fi
          sleep 1
        done

        count=$(cat "$STATE_DIRECTORY/count" 2>/dev/null || echo 0)
        if [ "$count" -ge ${toString cfg.maxRollbacks} ]; then
          echo "already rolled back $count times, leaving this generation in place" >&2
          exit 0
        fi

        echo "no tailnet address after ${toString cfg.graceSeconds}s, rolling back" >&2
        if ! ${config.nix.package}/bin/nix-env --rollback -p /nix/var/nix/profiles/system; then
          echo "nothing older to roll back to, leaving this generation in place" >&2
          exit 0
        fi

        echo $((count + 1)) > "$STATE_DIRECTORY/count"
        /nix/var/nix/profiles/system/bin/switch-to-configuration boot || true
        ${pkgs.systemd}/bin/systemctl --no-block reboot
      '';
    };

    system.activationScripts.rollback-guard = lib.stringAfter [ "etc" ] ''
      ${pkgs.systemd}/bin/systemctl restart --no-block rollback-guard.service || true
    '';
  };
}

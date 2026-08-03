# Tailscale, with the kill switch opened for it.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.server.tailscale;
in

{
  options.local.server.tailscale = {
    enable = lib.mkEnableOption "the tailscale daemon";

    port = lib.mkOption {
      type = lib.types.port;
      default = 41641;
      description = "Fixed listen port, so the firewall rule is static.";
    };

    ssh = lib.mkEnableOption "Tailscale SSH";

    # Routes still need approving in the tailscale admin console.
    advertiseRoutes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "192.168.1.0/24" ];
      description = "LAN subnets this host routes for the tailnet.";
    };

    authKeySecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of a sops secret holding a tailnet auth key. Null means enrol once
        by hand with `tailscale up`, which avoids storing a key at all.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.tailscale = {
          enable = true;
          inherit (cfg) port;
          openFirewall = true;
          useRoutingFeatures = if cfg.advertiseRoutes == [ ] then "none" else "server";
          extraUpFlags =
            lib.optional cfg.ssh "--ssh"
            ++ lib.optional (
              cfg.advertiseRoutes != [ ]
            ) "--advertise-routes=${lib.concatStringsSep "," cfg.advertiseRoutes}";
          extraSetFlags =
            lib.optional cfg.ssh "--ssh"
            ++ lib.optional (
              cfg.advertiseRoutes != [ ]
            ) "--advertise-routes=${lib.concatStringsSep "," cfg.advertiseRoutes}";
        };

        # Use native nftables backend.
        systemd.services.tailscaled.environment.TS_DEBUG_FIREWALL_MODE = "nftables";

        # Control-plane and DERP traffic goes out the physical link; replies to
        # tailnet peers leave via the tunnel and are not marked, so both are needed.
        local.vpn.bypassUnits = [ "tailscaled.service" ];
        local.vpn.allowInterfaces = [ "tailscale0" ];

        # wg-quick adds its redirect without an explicit priority, and the kernel
        # places it just below whatever rules already exist, so a hardcoded
        # number here gets undercut on the next tunnel restart. Read wg-quick's
        # actual priority and sit one below it. Fixed Tailscale ranges, not
        # specific to this tailnet.
        systemd.services.tailscale-route-priority = {
          description = "Route tailnet addresses ahead of the VPN kill switch";
          after = [
            "tailscaled.service"
            "wg-quick-proton.service"
            "wg-quick-proton-alt.service"
          ];
          wants = [ "tailscaled.service" ];
          # Restarted with either tunnel: wg-quick re-adds its rules below ours
          # on every start, so the priority has to be recomputed each time.
          partOf = [
            "tailscaled.service"
            "wg-quick-proton.service"
            "wg-quick-proton-alt.service"
          ];
          wantedBy = [
            "multi-user.target"
            "wg-quick-proton.service"
            "wg-quick-proton-alt.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ip=${pkgs.iproute2}/bin/ip
            for family in "-4" "-6"; do
              case "$family" in
                -4) net=100.64.0.0/10 ;;
                -6) net=fd7a:115c:a1e0::/48 ;;
              esac

              $ip $family rule show 2>/dev/null \
                | ${pkgs.gawk}/bin/awk -v n="$net" '$0 ~ n { sub(":","",$1); print $1 }' \
                | while read -r old; do $ip $family rule del to "$net" lookup 52 priority "$old" 2>/dev/null || true; done

              wg=$($ip $family rule show 2>/dev/null \
                | ${pkgs.gawk}/bin/awk '/not .*fwmark 0xca6c/ || /suppress_prefixlength/ { sub(":","",$1); print $1 }' \
                | sort -n | head -1)
              prio=$(( ''${wg:-50} - 1 ))
              [ "$prio" -lt 1 ] && prio=1

              $ip $family rule add to "$net" lookup 52 priority "$prio" || true
              echo "tailnet $net via table 52 at priority $prio (wg-quick at ''${wg:-none})"
            done
          '';
        };
      }

      (lib.mkIf (cfg.authKeySecret != null) {
        sops.secrets.${cfg.authKeySecret} = { };

        services.tailscale.authKeyFile = config.sops.secrets.${cfg.authKeySecret}.path;

        systemd.services.tailscaled = {
          after = [ "sops-install-secrets.service" ];
          wants = [ "sops-install-secrets.service" ];
        };

        systemd.services.tailscaled-autoconnect = {
          # Enrollment must not hold up or fail a system activation. Start it
          # from a timer and retry transient failures in the background.
          wantedBy = lib.mkForce [ ];
          after = [
            "network-online.target"
            "novpn-tailscaled-service.service"
            "sops-install-secrets.service"
          ];
          wants = [
            "network-online.target"
            "sops-install-secrets.service"
          ];
          serviceConfig = {
            TimeoutStartSec = "20s";
            Restart = "on-failure";
            RestartSec = "1min";
          };
        };

        systemd.timers.tailscaled-autoconnect = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "5s";
            Unit = "tailscaled-autoconnect.service";
          };
        };
      })
    ]
  );
}

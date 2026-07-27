# Tailscale, with the kill switch opened for it.

{ config, lib, ... }:

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
          extraUpFlags = lib.optional (
            cfg.advertiseRoutes != [ ]
          ) "--advertise-routes=${lib.concatStringsSep "," cfg.advertiseRoutes}";
          extraSetFlags = lib.optional (
            cfg.advertiseRoutes != [ ]
          ) "--advertise-routes=${lib.concatStringsSep "," cfg.advertiseRoutes}";
        };

        # Control-plane and DERP traffic goes out the physical link; replies to
        # tailnet peers leave via the tunnel and are not marked, so both are needed.
        local.vpn.bypassUnits = [ "tailscaled.service" ];
        local.vpn.allowInterfaces = [ "tailscale0" ];
      }

      (lib.mkIf (cfg.authKeySecret != null) {
        sops.secrets.${cfg.authKeySecret} = { };

        services.tailscale.authKeyFile = config.sops.secrets.${cfg.authKeySecret}.path;

        systemd.services.tailscaled = {
          after = [ "sops-install-secrets.service" ];
          wants = [ "sops-install-secrets.service" ];
        };
      })
    ]
  );
}

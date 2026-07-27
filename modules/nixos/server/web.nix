# Public read-only hosting: nginx on loopback, exposed only via Cloudflare Tunnel.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.web.public;

  placeholder = pkgs.runCommand "site-placeholder" { } ''
    mkdir -p $out
    echo '<!doctype html><title>placeholder</title><h1>placeholder</h1>' > $out/index.html
  '';
in

{
  options.local.web.public = {
    enable = lib.mkEnableOption "public web hosting behind a Cloudflare Tunnel";

    tunnelId = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Cloudflare tunnel UUID.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
    };

    hostnames = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.package);
      default = { };
      description = ''
        Hostname to static root. A null root serves a placeholder. Access
        policies for the login-gated hostnames live in the Cloudflare dashboard,
        not here.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Stays root-owned: the unit is DynamicUser and pulls this in via
    # LoadCredential, which reads it as root before entering the sandbox.
    sops.secrets.cloudflared-credentials = {
      restartUnits = [ "cloudflared-tunnel-${cfg.tunnelId}.service" ];
    };

    services.cloudflared = {
      enable = true;
      tunnels.${cfg.tunnelId} = {
        credentialsFile = config.sops.secrets.cloudflared-credentials.path;
        default = "http_status:404";
        ingress = lib.mapAttrs (_: _: "http://127.0.0.1:${toString cfg.port}") cfg.hostnames;
      };
    };

    local.vpn.bypassUnits = [ "cloudflared-tunnel-${cfg.tunnelId}.service" ];

    services.nginx = {
      enable = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;
      recommendedProxySettings = true;
      defaultListen = [
        {
          addr = "127.0.0.1";
          port = cfg.port;
          ssl = false;
        }
      ];
      virtualHosts = lib.mapAttrs (_: root: {
        root = toString (if root == null then placeholder else root);
        extraConfig = ''
          client_max_body_size 1k;
        '';
        # limit_except is only valid inside a location block.
        locations."/".extraConfig = ''
          limit_except GET HEAD { deny all; }
        '';
      }) cfg.hostnames;
    };

    # Loopback-only on a high port, so it needs no binding capabilities at all
    # and can refuse every address but localhost.
    systemd.services.nginx.serviceConfig = {
      CapabilityBoundingSet = [ "" ];
      AmbientCapabilities = lib.mkForce [ "" ];
      IPAddressAllow = [ "localhost" ];
      IPAddressDeny = "any";
      DevicePolicy = "closed";
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RemoveIPC = true;
      UMask = lib.mkForce "0077";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateDevices = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "~@resources"
      ];
    };

    assertions = [
      {
        assertion = cfg.tunnelId != "";
        message = "local.web.public.tunnelId must be set to the Cloudflare tunnel UUID.";
      }
      {
        assertion = cfg.port >= 1024;
        message = "local.web.public.port must stay above 1024; nginx runs with no capabilities here.";
      }
      {
        assertion = cfg.hostnames != { };
        message = "local.web.public has no hostnames, so the tunnel serves only its 404 catch-all.";
      }
    ];
  };
}

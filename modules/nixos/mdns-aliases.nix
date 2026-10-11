# Extra mDNS names for this host, so a LAN device with no Tailscale can use a name.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.mdns;

  publish = pkgs.writeShellScript "mdns-aliases" ''
    ${lib.concatMapStringsSep "\n" (name: ''
      ${pkgs.avahi}/bin/avahi-publish --address --no-reverse ${lib.escapeShellArg name} ${cfg.address} &
    '') cfg.names}
    wait -n
  '';
in
{
  options.local.mdns = {
    address = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Address the published names resolve to.";
    };

    names = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Names to publish over mDNS, each ending in .local.";
    };
  };

  config = lib.mkIf (cfg.names != [ ]) {
    assertions = [
      {
        assertion = cfg.address != "";
        message = "local.mdns.names needs local.mdns.address to publish them against.";
      }
      {
        assertion = lib.all (name: lib.hasSuffix ".local" name) cfg.names;
        message = "local.mdns.names must each end in .local; mDNS serves no other domain.";
      }
    ];

    services.avahi = {
      enable = true;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = true;
        # avahi refuses an entry group from any client, address records included, while
        # user-service publishing is off: "Failed to create entry group: Not permitted".
        userServices = true;
      };
    };

    systemd.services.mdns-aliases = {
      description = "Publish this host's extra names over mDNS";
      after = [ "avahi-daemon.service" ];
      wants = [ "avahi-daemon.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = publish;
        Restart = "always";
        RestartSec = "10s";
        DynamicUser = true;
        MemoryMax = "32M";
        CapabilityBoundingSet = [ "" ];
        AmbientCapabilities = [ "" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectProc = "invisible";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
      };
    };
  };
}

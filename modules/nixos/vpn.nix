# Proton WireGuard tunnels, fail-closed kill switch, and per-unit VPN bypass.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.vpn;

  unitTableName = unit: "novpn-" + lib.replaceStrings [ "." "@" "\\" ] [ "-" "-" "-" ] unit;

  bypassRules =
    unit:
    pkgs.writeText "${unitTableName unit}.nft" ''
      table inet ${unitTableName unit} {
        chain output {
          type route hook output priority mangle; policy accept;
          socket cgroupv2 level 2 "system.slice/${unit}" meta mark set 0xca6c
        }
      }
    '';

  # Own table per unit, loaded after the unit exists: a missing cgroup path
  # aborts the whole nft transaction, which must not take the killswitch with it.
  bypassService = unit: {
    name = unitTableName unit;
    value = {
      description = "Route ${unit} around the VPN";
      after = [
        "nftables.service"
        unit
      ];
      wants = [ unit ];
      partOf = [ "nftables.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.nftables}/bin/nft -f ${bypassRules unit}";
        ExecStop = "-${pkgs.nftables}/bin/nft delete table inet ${unitTableName unit}";
      };
    };
  };

  allowedInterfaces = lib.concatStringsSep ", " (
    map (i: ''"${i}"'') (
      [
        "proton"
        "proton-2"
      ]
      ++ cfg.allowInterfaces
    )
  );
in

{
  options.local.vpn = {
    bypassUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Systemd units whose sockets are marked 0xca6c, routing them out the
        physical link instead of the tunnel. The kill switch already accepts
        that mark, so marking is also what lets them out at all.
      '';
    };

    allowInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra output interfaces the kill switch accepts, for tunnels the host
        terminates itself (tailscale0). Traffic leaving this way is not marked,
        so it needs an explicit accept.
      '';
    };
  };

  config = {
    local.vpn.bypassUnits = [ "nix-daemon.service" ];

    networking.networkmanager.unmanaged = [
      "interface-name:proton"
      "interface-name:proton-2"
    ];
    sops.secrets.proton-wg = { };
    sops.secrets.proton-wg-2 = { };
    networking.wg-quick.interfaces.proton = {
      configFile = config.sops.secrets.proton-wg.path;
      autostart = false;
    };
    networking.wg-quick.interfaces.proton-2.configFile = config.sops.secrets.proton-wg-2.path;
    systemd.services = lib.listToAttrs (map bypassService cfg.bypassUnits) // {
      "wg-quick-proton" = {
        after = [ "sops-install-secrets.service" ];
        wants = [ "sops-install-secrets.service" ];
        conflicts = [ "wg-quick-proton-2.service" ];
      };
      "wg-quick-proton-2" = {
        after = [ "sops-install-secrets.service" ];
        wants = [ "sops-install-secrets.service" ];
        conflicts = [ "wg-quick-proton.service" ];
      };
    };

    # Fail-closed VPN kill switch: drop all egress except loopback, the tunnel
    # interfaces, WireGuard's own marked packets, LAN, and DHCP. Active even
    # before a tunnel comes up, so the real IP can't leak in the boot race.
    # 0xca6c is the fwmark wg-quick puts on encrypted packets (table 51820);
    # 0xca6d covers a brief overlap if both tunnels race during a switch.
    networking.nftables.enable = true;
    networking.nftables.tables.vpn-killswitch = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority 0; policy drop;

          oifname "lo" accept
          oifname { ${allowedInterfaces} } accept
          meta mark { 0xca6c, 0xca6d } accept

          udp dport { 67, 68 } accept
          ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 255.255.255.255, 224.0.0.0/4 } accept
          ip6 daddr { fe80::/10, ff00::/8 } accept

          counter drop
        }
      '';
    };

    # Split tunnel: traffic from the "novpn" group bypasses the VPN. Marking it
    # 0xca6c makes wg-quick's rules route it out the physical link instead of the
    # tunnel, and the kill switch above already accepts that mark. DNS stays on
    # the default path so it resolves via the tunnel's resolver while VPN is up.
    # The reroute happens after the socket already picked the tunnel source IP,
    # so masquerade rewrites it to the physical address (matched by skgid, not
    # the mark, to leave WireGuard's own encrypted packets untouched).
    users.groups.novpn.gid = 700;
    networking.nftables.tables.novpn-split = {
      family = "inet";
      content = ''
        chain output {
          type route hook output priority mangle; policy accept;

          meta skgid 700 udp dport 53 return
          meta skgid 700 tcp dport 53 return
          meta skgid 700 meta mark set 0xca6c
        }

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;

          meta mark 0xca6c oifname != { "lo", "proton", "proton-2" } masquerade
        }
      '';
    };

    # Split-tunnel replies arrive on the physical link though the route to their
    # source is via the tunnel; strict reverse-path filtering would drop them.
    networking.firewall.checkReversePath = "loose";
  };
}

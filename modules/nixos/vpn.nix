# Proton WireGuard tunnels, fail-closed kill switch, and per-unit VPN bypass.

{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

let
  cfg = config.local.vpn;
  nixDaemonNovpn = import ./nix-daemon-novpn.nix {
    inherit pkgs;
    nixPackage = config.nix.package;
  };
  nixClientCommands = [
    "nix"
    "nix-build"
    "nix-channel"
    "nix-collect-garbage"
    "nix-copy-closure"
    "nix-env"
    "nix-hash"
    "nix-instantiate"
    "nix-prefetch-url"
    "nix-shell"
    "nix-store"
  ];

  # Nix drops any inherited setgid privilege at startup (getgid() !=
  # getegid() triggers a defensive setresgid back to the real gid), so a
  # plain setgid bit on these binaries is a no-op. Route through sg instead,
  # which sets the *real* gid, so Nix has nothing to drop and the whole
  # process tree it spawns (including an entered nix-shell and everything
  # run inside it) keeps skgid 700.
  novpnWrapper =
    name: bin:
    pkgs.writeShellApplication {
      name = "${name}-novpn";
      text = ''
        args=$(printf '%q ' "$@")
        exec /run/wrappers/bin/sg novpn -c "exec ${bin} $args"
      '';
    };

  unitTableName = unit: "novpn-" + lib.replaceStrings [ "." "@" "\\" ] [ "-" "-" "-" ] unit;

  bypassRules =
    unit:
    pkgs.writeText "${unitTableName unit}.nft" ''
      table inet ${unitTableName unit} {
        chain output {
          type route hook output priority mangle + 1; policy accept;
          socket cgroupv2 level 2 "system.slice/${unit}" counter meta mark set 0xca6c
        }
      }
    '';

  # Own table per unit, loaded after the unit exists: a missing cgroup path
  # aborts the whole nft transaction, which must not take the killswitch with it.
  # PartOf the unit too: nft resolves the cgroup path to an ID at load time, so a
  # restart of the unit leaves the rule pointing at a dead cgroup and the traffic
  # unmarked. Restarting alongside it re-resolves against the new cgroup.
  bypassService = unit: {
    name = unitTableName unit;
    value = {
      description = "Route ${unit} around the VPN";
      after = [
        "nftables.service"
        unit
      ];
      wants = [ unit ];
      partOf = [
        "nftables.service"
        unit
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.nftables}/bin/nft -f ${bypassRules unit}";
        ExecStop = "-${pkgs.nftables}/bin/nft delete table inet ${unitTableName unit}";
      };
    };
  };

  vpnNames = lib.attrNames cfg.configs;

  allowedInterfaces = lib.concatStringsSep ", " (
    map (i: ''"${i}"'') (map (n: "proton-${n}") vpnNames ++ cfg.allowInterfaces)
  );
in

{
  options.local.vpn.configs = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    example = {
      uk = "proton-wg-laptop-uk";
      nl = "proton-wg-laptop-nl";
    };
    description = "Interface suffix to sops secret, one set per host.";
  };

  options.local.vpn.bypassUnits = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Units whose sockets are marked 0xca6c, routed around the tunnel.";
  };

  options.local.vpn.allowInterfaces = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Extra output interfaces the kill switch accepts.";
  };

  options.local.vpn.primary = lib.mkOption {
    type = lib.types.str;
    description = "Which entry in configs autostarts.";
  };

  options.local.vpn.bypassResolver = lib.mkOption {
    type = lib.types.str;
    default = "1.1.1.1";
    description = "Resolver for novpn traffic, reachable off the tunnel.";
  };

  config = {
    users.groups.novpn.gid = 700;
    users.users.max.extraGroups = [ "novpn" ];

    local.vpn.bypassUnits = [
      "nix-daemon.service"
    ]
    ++ lib.optional config.services.tailscale.enable "tailscaled.service";

    local.vpn.allowInterfaces = lib.optional config.services.tailscale.enable "tailscale0";

    environment.systemPackages = [ nixDaemonNovpn ];

    security.wrappers =
      lib.genAttrs nixClientCommands (command: {
        source = "${novpnWrapper command "${config.nix.package}/bin/${command}"}/bin/${command}-novpn";
        owner = "root";
        group = "root";
        permissions = "u+rx,g+rx,o+rx";
      })
      // {
        nixos-rebuild = {
          source = "${novpnWrapper "nixos-rebuild" "${pkgs.nixos-rebuild-ng}/bin/nixos-rebuild"}/bin/nixos-rebuild-novpn";
          owner = "root";
          group = "root";
          permissions = "u+rx,g+rx,o+rx";
        };
        nh = {
          source = "${novpnWrapper "nh" "${pkgs.nh}/bin/nh"}/bin/nh-novpn";
          owner = "root";
          group = "root";
          permissions = "u+rx,g+rx,o+rx";
        };
        home-manager = {
          source = "${novpnWrapper "home-manager" "${
            inputs.home-manager.packages.${pkgs.stdenv.hostPlatform.system}.default
          }/bin/home-manager"}/bin/home-manager-novpn";
          owner = "root";
          group = "root";
          permissions = "u+rx,g+rx,o+rx";
        };
      };

    networking.networkmanager.unmanaged = map (n: "interface-name:proton-${n}") vpnNames;

    sops.secrets = lib.mapAttrs' (_: secret: lib.nameValuePair secret { }) cfg.configs;

    networking.wg-quick.interfaces = lib.mapAttrs' (
      name: secret:
      lib.nameValuePair "proton-${name}" {
        configFile = config.sops.secrets.${secret}.path;
        autostart = name == cfg.primary;
      }
    ) cfg.configs;

    systemd.services = lib.listToAttrs (map bypassService cfg.bypassUnits) // {
      nix-daemon.serviceConfig.Group = "novpn";
    }
    // lib.mapAttrs' (
      name: _:
      lib.nameValuePair "wg-quick-proton-${name}" {
        conflicts = map (o: "wg-quick-proton-${o}.service") (lib.remove name vpnNames);
      }
    ) cfg.configs;

    assertions = [
      {
        assertion = cfg.configs ? ${cfg.primary};
        message = "local.vpn.primary \"${cfg.primary}\" is not a key in local.vpn.configs.";
      }
    ];

    # Fail-closed VPN kill switch: drop all egress except loopback, the tunnel
    # interfaces, WireGuard's own marked packets, LAN, and DHCP. Active even
    # before a tunnel comes up, so the real IP can't leak in the boot race.
    # 0xca6c is the fwmark wg-quick puts on encrypted packets (table 51820);
    # 0xca6d covers a brief overlap during a tunnel restart.
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
    # tunnel, and the kill switch above already accepts that mark.
    # The reroute happens after the socket already picked the tunnel source IP,
    # so masquerade rewrites it to the physical address (matched by skgid, not
    # the mark, to leave WireGuard's own encrypted packets untouched).
    networking.nftables.tables.novpn-split = {
      family = "inet";
      content = ''
        chain output {
          type route hook output priority mangle + 1; policy accept;

          meta skgid 700 counter meta mark set 0xca6c
        }

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;

          meta mark 0xca6c oifname != { "lo", ${lib.concatMapStringsSep ", " (n: "\"proton-${n}\"") vpnNames} } masquerade
        }
      '';
    };

    # resolv.conf points at the tunnel resolver, which bypassed traffic cannot
    # reach by definition. Send its queries to a resolver on the physical link.
    networking.nftables.tables.novpn-dns = {
      family = "ip";
      content = ''
        chain output {
          type nat hook output priority dstnat; policy accept;

          ip daddr 100.100.100.100 return

          meta mark 0xca6c udp dport 53 dnat to ${cfg.bypassResolver}
          meta mark 0xca6c tcp dport 53 dnat to ${cfg.bypassResolver}
        }
      '';
    };

    # Split-tunnel replies arrive on the physical link though the route to their
    # source is via the tunnel; strict reverse-path filtering would drop them.
    networking.firewall.checkReversePath = "loose";
  };
}

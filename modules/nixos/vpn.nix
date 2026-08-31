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
  unitTableName = unit: "novpn-" + lib.replaceStrings [ "." "@" "\\" ] [ "-" "-" "-" ] unit;

  novpnGid = 700;

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

  tailnetRouteService = {
    name = "tailnet-route-${cfg.interface}";
    value = {
      description = "Route the tailnet around ${cfg.interface}";
      after = [ "wg-quick-${cfg.interface}.service" ];
      partOf = [ "wg-quick-${cfg.interface}.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.iproute2}/bin/ip rule add to 100.64.0.0/10 lookup 52 priority 5207";
        ExecStop = "-${pkgs.iproute2}/bin/ip rule del to 100.64.0.0/10 lookup 52 priority 5207";
      };
    };
  };

  bootstrapConf = "/run/proton/${cfg.interface}.conf";

  selection = cfg.selection;
  selectionEnabled = selection.countries != [ ];

  confgen = import ./protonvpn-wg-confgen.nix { inherit pkgs; };

  bypassResolvConf = pkgs.writeText "vpn-switch-resolv.conf" ''
    nameserver ${cfg.bypassResolver}
  '';

  vpnSwitch = pkgs.writeShellApplication {
    name = "vpn-switch";
    runtimeInputs = with pkgs; [
      confgen
      wireguard-tools
      util-linux
      coreutils
      gawk
      iputils
    ];
    text = /* bash */ ''
      usage() {
        printf '%s\n' \
          'vpn-switch - pick a Proton server and apply it to the live tunnel' \
          "" \
          'usage:' \
          '  vpn-switch                    re-pick per the configured policy' \
          '  vpn-switch --country XX[,YY]  override the country for this switch' \
          '  vpn-switch --server NAME      use one exact server, e.g. UK#42' \
          '  vpn-switch --secure-core      restrict to Secure Core servers' \
          '  vpn-switch --no-secure-core   allow ordinary servers' \
          '  vpn-switch --p2p|--no-p2p     require or ignore P2P support' \
          '  vpn-switch --list             show candidate servers and exit' \
          '  vpn-switch --status           show the current peer and handshake' \
          '  vpn-switch --bootstrap FILE   write a config for wg-quick, do not apply' \
          '  vpn-switch --help             this text' \
          "" \
          'The peer is swapped on the running interface, so no unit is restarted.' \
          'On failure the previous peer is restored.'
      }

      case "''${1:-}" in
        --help|-h) usage; exit 0 ;;
      esac

      if [ "$(id -u)" -ne 0 ]; then
        exec sudo -- "$0" "$@"
      fi

      if [ "''${VPN_SWITCH_NS:-}" != "1" ]; then
        export VPN_SWITCH_NS=1
        exec unshare --mount --propagation private -- "$0" "$@"
      fi
      mount --bind ${bypassResolvConf} /etc/resolv.conf

      countries="${lib.concatStringsSep "," selection.countries}"
      pool="${toString selection.poolSize}"
      server=""
      status=0
      bootstrap=""
      list=0
      secure=${lib.boolToString selection.secureCore}
      p2p=${lib.boolToString selection.p2p}

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --country) countries="$2"; shift 2 ;;
          --server) server="$2"; shift 2 ;;
          --bootstrap) bootstrap="$2"; shift 2 ;;
          --status) status=1; shift ;;
          --list) list=1; shift ;;
          --secure-core) secure=true; shift ;;
          --no-secure-core) secure=false; shift ;;
          --p2p) p2p=true; shift ;;
          --no-p2p) p2p=false; shift ;;
          *) usage >&2; exit 2 ;;
        esac
      done

      selectFlags=(-no-session "-p2p-only=$p2p")
      if [ "$secure" = true ]; then
        selectFlags+=(-secure-core)
      fi

      iface=""
      if [ -z "$bootstrap" ] && [ "$list" -eq 0 ]; then
        for _ in $(seq 1 30); do
          for candidate in $(wg show interfaces); do
            case "$candidate" in ${cfg.interface}) iface="$candidate"; break ;; esac
          done
          [ -n "$iface" ] && break
          sleep 1
        done
        if [ -z "$iface" ]; then
          echo "no proton interface came up" >&2
          exit 1
        fi
      fi

      if [ "$status" -eq 1 ]; then
        wg show "$iface"
        exit 0
      fi

      PROTONVPN_USERNAME="$(cat ${config.sops.secrets.${cfg.usernameSecret}.path})"
      PROTONVPN_PASSWORD="$(cat ${config.sops.secrets.${cfg.passwordSecret}.path})"
      export PROTONVPN_USERNAME PROTONVPN_PASSWORD

      rundir="$(mktemp -d -p /run vpn-switch.XXXXXX)"
      chmod 700 "$rundir"
      trap 'rm -rf "$rundir"' EXIT

      confgen() {
        setpriv --regid ${toString novpnGid} --clear-groups protonvpn-wg "$@"
      }

      backup="$rundir/backup.conf"
      if [ -z "$bootstrap" ] && [ "$list" -eq 0 ]; then
        wg showconf "$iface" > "$backup"
        fwmark="$(wg show "$iface" fwmark)"
      fi

      healthy() {
        since="$1"
        echo "waiting for handshake" >&2
        for _ in $(seq 1 20); do
          latest="$(wg show "$iface" latest-handshakes | awk '{print $2}' | sort -n | tail -1)"
          if [ "''${latest:-0}" -ge "$since" ] && ping -c 1 -W 2 ${cfg.healthProbe} >/dev/null 2>&1; then
            return 0
          fi
          sleep 1
        done
        return 1
      }

      apply() {
        conf="$rundir/wg.conf"
        echo "generating config for $1" >&2
        confgen -server "$1" -no-save -output "$conf" >/dev/null
        if [ -n "$bootstrap" ]; then
          install -D -m 600 "$conf" "$bootstrap"
          rm -f "$conf"
          return 0
        fi
        echo "applying $1" >&2
        started="$(date +%s)"
        wg syncconf "$iface" <(wg-quick strip "$conf")
        rm -f "$conf"
        if [ "$fwmark" != "off" ]; then
          wg set "$iface" fwmark "$fwmark"
        fi
        healthy "$started"
      }

      if [ -n "$server" ]; then
        if apply "$server"; then
          echo "''${iface:-bootstrap} -> $server"
          exit 0
        fi
        wg syncconf "$iface" "$backup"
        echo "$server did not come up; restored previous peer" >&2
        exit 1
      fi

      echo "listing servers for $countries" >&2
      candidates="$(
        confgen -list-servers -countries "$countries" "''${selectFlags[@]}" \
          | awk '
              match($0, /[A-Z0-9-]+#[0-9]+/) {
                name = substr($0, RSTART, RLENGTH)
                if (match($0, /[0-9]+% +[0-9]+\.[0-9]+/)) {
                  split(substr($0, RSTART, RLENGTH), f, /[% ]+/)
                  print f[2], name
                }
              }' \
          | sort -n | head -n "$pool" | cut -d' ' -f2 | shuf
      )"

      if [ -z "$candidates" ]; then
        echo "no servers matched countries=$countries" >&2
        exit 1
      fi

      if [ "$list" -eq 1 ]; then
        echo "$candidates"
        exit 0
      fi

      for name in $candidates; do
        if apply "$name"; then
          echo "''${iface:-bootstrap} -> $name"
          exit 0
        fi
        echo "$name did not come up, trying next" >&2
      done

      if [ -n "$bootstrap" ]; then
        echo "no candidate could be generated" >&2
        exit 1
      fi

      wg syncconf "$iface" "$backup"
      echo "no candidate came up; restored previous peer" >&2
      exit 1
    '';
  };

  vpnSwitchCompletion = pkgs.writeText "vpn-switch.bash" ''
    _vpn_switch() {
      local cur prev
      cur="''${COMP_WORDS[COMP_CWORD]}"
      prev="''${COMP_WORDS[COMP_CWORD-1]}"
      case "$prev" in
        --country)
          COMPREPLY=($(compgen -W "${lib.concatStringsSep " " selection.countries}" -- "$cur"))
          return
          ;;
        --server|--bootstrap)
          return
          ;;
      esac
      COMPREPLY=($(compgen -W "--country --server --list --status --secure-core --no-secure-core --p2p --no-p2p --bootstrap --help" -- "$cur"))
    }
    complete -F _vpn_switch vpn-switch
  '';

  vpnSwitchPkg = pkgs.symlinkJoin {
    name = "vpn-switch";
    paths = [ vpnSwitch ];
    postBuild = ''
      install -Dm444 ${vpnSwitchCompletion} $out/share/bash-completion/completions/vpn-switch
    '';
  };

  allowedInterfaces = lib.concatStringsSep ", " (
    map (i: ''"${i}"'') ([ cfg.interface ] ++ cfg.allowInterfaces)
  );

  # NetworkManager fires "up" only once an interface reaches full L3 activation,
  # so this catches SSID switches, WiFi drops, cable plugs and suspend/resume
  # alike, not just the boot race.
  protonReconnect = pkgs.writeShellScript "proton-reconnect" ''
    action="$2"
    [ "$action" = "up" ] || exit 0
    systemctl is-active --quiet wg-quick-${cfg.interface}.service && exit 0
    systemctl restart proton-bootstrap.service
    systemctl restart wg-quick-${cfg.interface}.service
  '';
in

{
  options.local.vpn.interface = lib.mkOption {
    type = lib.types.str;
    default = "proton";
    description = "Name of the WireGuard interface carrying the tunnel.";
  };

  options.local.vpn.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    readOnly = true;
    description = "Whether the Proton split tunnel module is present.";
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

  options.local.vpn.bypassResolver = lib.mkOption {
    type = lib.types.str;
    default = "1.1.1.1";
    description = "Resolver for novpn traffic, reachable off the tunnel.";
  };

  options.local.vpn.usernameSecret = lib.mkOption {
    type = lib.types.str;
    default = "proton-username";
    description = "Sops secret holding the Proton account username.";
  };

  options.local.vpn.passwordSecret = lib.mkOption {
    type = lib.types.str;
    default = "proton-password";
    description = "Sops secret holding the Proton account password.";
  };

  options.local.vpn.healthProbe = lib.mkOption {
    type = lib.types.str;
    default = "1.1.1.1";
    description = "Address pinged through the tunnel to accept a new peer.";
  };

  options.local.vpn.selection = {
    countries = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Exit countries the picker may choose from; empty disables picking.";
    };

    secureCore = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Restrict the picker to Secure Core servers.";
    };

    p2p = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Restrict the picker to P2P servers.";
    };

    poolSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
      description = "Pick at random among this many lowest-scoring servers.";
    };

    rotateEvery = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "6h";
      description = "Systemd interval at which to re-pick a server, or null.";
    };
  };

  config = {
    users.groups.novpn.gid = novpnGid;
    users.users.max.extraGroups = [ "novpn" ];

    local.vpn.bypassUnits = [
      "nix-daemon.service"
    ];

    local.vpn.allowInterfaces = lib.optional config.services.tailscale.enable "tailscale0";

    environment.systemPackages = [ nixDaemonNovpn ] ++ lib.optional selectionEnabled vpnSwitchPkg;

    networking.networkmanager.unmanaged = [
      "interface-name:${cfg.interface}"
    ]
    ++ lib.optional config.services.tailscale.enable "interface-name:tailscale0";

    networking.networkmanager.dispatcherScripts = lib.optional selectionEnabled {
      source = protonReconnect;
      type = "basic";
    };

    sops.secrets = lib.optionalAttrs selectionEnabled {
      ${cfg.usernameSecret}.mode = "0400";
      ${cfg.passwordSecret}.mode = "0400";
    };

    networking.wg-quick.interfaces.${cfg.interface} = {
      configFile = bootstrapConf;
      autostart = true;
    };

    systemd.services =
      lib.listToAttrs (map bypassService cfg.bypassUnits)
      // {
        nix-daemon.serviceConfig.Group = "novpn";
      }
      // lib.optionalAttrs config.services.tailscale.enable {
        tailscaled.serviceConfig.Group = "novpn";
      }
      // lib.optionalAttrs config.services.tailscale.enable (lib.listToAttrs [ tailnetRouteService ])
      // lib.optionalAttrs selectionEnabled {
        proton-bootstrap = {
          description = "Generate the initial Proton config for ${cfg.interface}";
          before = [ "wg-quick-${cfg.interface}.service" ];
          wantedBy = [ "wg-quick-${cfg.interface}.service" ];
          after = [
            "sops-install-secrets.service"
            "network-online.target"
          ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            Group = "novpn";
            ExecStart = "${vpnSwitchPkg}/bin/vpn-switch --bootstrap ${bootstrapConf}";
            Restart = "on-failure";
            RestartSec = 5;
            StartLimitIntervalSec = 60;
            StartLimitBurst = 8;
          };
        };

        "wg-quick-${cfg.interface}".serviceConfig = {
          Restart = "on-failure";
          RestartSec = 5;
          StartLimitIntervalSec = 60;
          StartLimitBurst = 8;
        };

        vpn-autoselect = {
          description = "Pick a Proton server for ${cfg.interface}";
          after = [
            "wg-quick-${cfg.interface}.service"
            "sops-install-secrets.service"
          ];
          partOf = [ "wg-quick-${cfg.interface}.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${vpnSwitchPkg}/bin/vpn-switch";
          };
        };
      };

    systemd.timers = lib.optionalAttrs (selectionEnabled && selection.rotateEvery != null) {
      vpn-autoselect = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnUnitActiveSec = selection.rotateEvery;
          RandomizedDelaySec = "10m";
        };
      };
    };

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

          meta skgid ${toString novpnGid} counter meta mark set 0xca6c
        }

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;

          meta mark 0xca6c oifname != { "lo", ${"\"${cfg.interface}\""} } masquerade
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

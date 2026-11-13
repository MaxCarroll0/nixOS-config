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

  unitSlice =
    unit:
    config.systemd.services.${lib.removeSuffix ".service" unit}.serviceConfig.Slice or "system.slice";

  bypassRules =
    unit:
    pkgs.writeText "${unitTableName unit}.nft" ''
      table inet ${unitTableName unit} {
        chain output {
          type route hook output priority mangle + 1; policy accept;
          socket cgroupv2 level 2 "${unitSlice unit}/${unit}" counter meta mark set 0xca6c
        }
      }
    '';

  # nft resolves the unit's cgroup to an ID at load time, so the table is PartOf the unit.
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
  serverFile = "/run/proton/${cfg.interface}.server";
  statusFile = "/run/proton/status.json";

  selection = cfg.selection;
  selectionEnabled = selection.countries != [ ];

  confgen = import ./protonvpn-wg-confgen.nix { inherit pkgs; };

  bypassResolvConf = pkgs.writeText "vpn-switch-resolv.conf" ''
    nameserver ${cfg.bypassResolver}
  '';

  disableTable = "vpn-disabled";

  # Reuses the split-tunnel mark the kill switch accepts, so disabling reloads only this table.
  disableRules = pkgs.writeText "${disableTable}.nft" ''
    table inet ${disableTable} {
      chain output {
        type route hook output priority mangle - 1; policy accept;

        oifname "${cfg.interface}" counter meta mark set 0xca6c
      }
    }
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
      nftables
    ];
    text = builtins.replaceStrings [ "@bypassResolvConf@" "@countries@" "@pool@" "@secure@" "@p2p@" "@disableTable@" "@disableRules@" "@interface@" "@usernameFile@" "@passwordFile@" "@novpnGid@" "@healthProbe@" "@moderateNat@" "@serverFile@" ] [
      "${bypassResolvConf}"
      "${lib.concatStringsSep "," selection.countries}"
      "${toString selection.poolSize}"
      "${lib.boolToString selection.secureCore}"
      "${lib.boolToString selection.p2p}"
      "${disableTable}"
      "${disableRules}"
      "${cfg.interface}"
      "${config.sops.secrets.${cfg.usernameSecret}.path}"
      "${config.sops.secrets.${cfg.passwordSecret}.path}"
      "${toString novpnGid}"
      "${cfg.healthProbe}"
      "${lib.optionalString cfg.moderateNat "-moderate-nat "}"
      "${serverFile}"
    ] (builtins.readFile ./vpn-switch.sh);
  };

  vpnStatus = pkgs.writeShellApplication {
    name = "vpn-status";
    runtimeInputs = with pkgs; [
      wireguard-tools
      nftables
      gawk
      jq
      coreutils
    ];
    text = /* bash */ ''
      busy="''${1:-}"
      failed="''${2:-}"
      iface=${cfg.interface}
      enabled=true
      if nft list table inet ${disableTable} >/dev/null 2>&1; then
        enabled=false
      fi
      up=false endpoint="" handshake=0 rx=0 tx=0
      if wg show "$iface" >/dev/null 2>&1; then
        up=true
        endpoint="$(wg show "$iface" endpoints | awk 'NR == 1 { print $2 }')"
        handshake="$(wg show "$iface" latest-handshakes | awk '{ print $2 }' | sort -n | tail -1)"
        read -r rx tx < <(wg show "$iface" transfer | awk '{ r += $2; t += $3 } END { print r + 0, t + 0 }')
      fi
      server="$(cat ${serverFile} 2>/dev/null || true)"
      json="$(jq -cn \
        --argjson enabled "$enabled" --argjson up "$up" \
        --arg server "$server" --arg endpoint "$endpoint" \
        --argjson handshake "''${handshake:-0}" --argjson rx "$rx" --argjson tx "$tx" \
        --arg busy "$busy" --arg failed "$failed" \
        --argjson countries '${builtins.toJSON selection.menuCountries}' \
        --argjson updated "$(date +%s)" \
        '$ARGS.named')"
      install -d -m 755 /run/proton
      printf '%s\n' "$json" > ${statusFile}
    '';
  };

  vpnCtl = pkgs.writeShellApplication {
    name = "vpn-ctl";
    runtimeInputs = [
      vpnSwitch
      vpnStatus
      pkgs.util-linux
    ];
    text = /* bash */ ''
      verb="$1"
      case "$verb" in
        status) exec vpn-status ;;
        repick) args=() ;;
        enable) args=(--enable) ;;
        disable) args=(--disable) ;;
        secure-core) args=(--secure-core) ;;
        country-*)
          country="''${verb#country-}"
          if ! [[ "$country" =~ ^[A-Z]{2}$ ]]; then
            echo "bad country: $country" >&2
            exit 2
          fi
          args=(--country "$country")
          ;;
        *) echo "unknown verb: $verb" >&2; exit 2 ;;
      esac

      exec 9> /run/proton/ctl.lock
      flock 9
      vpn-status "$verb"
      if vpn-switch "''${args[@]}"; then
        vpn-status
      else
        vpn-status "" "$verb"
        exit 1
      fi
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
      COMPREPLY=($(compgen -W "--country --server --list --status --disable --enable --secure-core --no-secure-core --p2p --no-p2p --bootstrap --help" -- "$cur"))
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

  # NetworkManager fires "up" only at full L3 activation, so this also catches SSID switches and resume.
  protonReconnect = pkgs.writeShellScript "proton-reconnect" ''
    action="$2"
    [ "$action" = "up" ] && [ "$1" != lo ] || exit 0
    systemctl is-active --quiet wg-quick-${cfg.interface}.service && exit 0
    [ -n "$(systemctl list-jobs --no-legend proton-bootstrap.service wg-quick-${cfg.interface}.service)" ] && exit 0
    systemctl restart --no-block proton-bootstrap.service
    systemctl restart --no-block wg-quick-${cfg.interface}.service
  '';
in

{
  options.local.vpn.interface = lib.mkOption {
    type = lib.types.str;
    default = "proton";
    description = "Name of the WireGuard interface carrying the tunnel; default proton.";
  };

  options.local.vpn.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    readOnly = true;
    description = "Whether the Proton split tunnel is set up; default on.";
  };

  options.local.vpn.bypassUnits = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Units whose sockets bypass the tunnel via fwmark 0xca6c; default none.";
  };

  options.local.vpn.allowInterfaces = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Extra output interfaces the kill switch accepts; default none.";
  };

  options.local.vpn.bypassResolver = lib.mkOption {
    type = lib.types.str;
    default = "1.1.1.1";
    description = "Resolver used by bypassed (novpn) traffic; default 1.1.1.1.";
  };

  options.local.vpn.usernameSecret = lib.mkOption {
    type = lib.types.str;
    default = "proton-username";
    description = "Sops secret holding the Proton account username; default proton-username.";
  };

  options.local.vpn.passwordSecret = lib.mkOption {
    type = lib.types.str;
    default = "proton-password";
    description = "Sops secret holding the Proton account password; default proton-password.";
  };

  options.local.vpn.healthProbe = lib.mkOption {
    type = lib.types.str;
    default = "1.1.1.1";
    description = "Address pinged through the tunnel to confirm a new peer works; default 1.1.1.1.";
  };

  options.local.vpn.moderateNat = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether to request Proton's Moderate NAT for direct peer connections; default off.";
  };

  options.local.vpn.selection = {
    countries = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Exit countries the picker may choose from; empty disables picking, default none.";
    };

    secureCore = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether the picker is restricted to Secure Core servers; default off.";
    };

    p2p = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether the picker is restricted to P2P servers; default on.";
    };

    poolSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
      description = "Number of lowest-load servers the picker chooses among at random; default 7.";
    };

    menuCountries = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.unique (
        selection.countries
        ++ [
          "UK"
          "NL"
          "DE"
          "CH"
          "SE"
          "US"
        ]
      );
      description = "Countries offered by the desktop VPN controller.";
    };

    rotateEvery = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "6h";
      description = "Systemd time span between automatic server re-picks; default null, meaning never.";
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
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${vpnSwitchPkg}/bin/vpn-switch";
            ExecStartPost = lib.getExe vpnStatus;
          };
        };

        "vpn-ctl@" = {
          description = "VPN controller action %i";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe vpnCtl} %i";
          };
        };

        vpn-status = {
          description = "Publish the VPN state to ${statusFile}";
          after = [ "wg-quick-${cfg.interface}.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe vpnStatus;
          };
        };
      };

    systemd.timers =
      lib.optionalAttrs selectionEnabled {
        vpn-status = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnActiveSec = "10s";
            OnUnitActiveSec = "1min";
            AccuracySec = "10s";
          };
        };
      }
      // lib.optionalAttrs (selectionEnabled && selection.rotateEvery != null) {
        vpn-autoselect = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnActiveSec = selection.rotateEvery;
            OnUnitActiveSec = selection.rotateEvery;
            RandomizedDelaySec = "10m";
          };
        };
      };

    security.polkit.extraConfig = lib.mkIf selectionEnabled ''
      polkit.addRule(function (action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units"
            && /^vpn-ctl@(status|repick|enable|disable|secure-core|country-[A-Z]{2})\.service$/.test(action.lookup("unit"))
            && action.lookup("verb") == "start"
            && subject.user == "max") {
          return polkit.Result.YES;
        }
      });
    '';

    # Fail-closed: all egress is dropped except loopback, the tunnel, WireGuard's marks, LAN and DHCP.
    # 0xca6c is the fwmark wg-quick puts on encrypted packets; 0xca6d covers a tunnel restart.
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

    # Marked novpn traffic leaves the physical link; masquerade by skgid rewrites its tunnel source address.
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

    # resolv.conf points at the tunnel resolver, which bypassed traffic cannot reach.
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

    # Replies to bypassed traffic arrive on the physical link, so strict rp_filter would drop them.
    networking.firewall.checkReversePath = "loose";
  };
}

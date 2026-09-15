# LAN-first connections between Max's machines. mDNS follows DHCP and NIC
# changes; literal tailnet addresses are used only when no LAN endpoint works.

{ config, pkgs, lib, ... }:

let
  cfg = config.local.peerTransport;
  peers = lib.attrValues cfg.peers;

  peerModule = { name, ... }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Name accepted by peer-connect.";
      };
      lanHost = lib.mkOption {
        type = lib.types.str;
        default = "${name}.local";
        description = "mDNS name used to discover the peer on the current LAN.";
      };
      tailscaleAddress = lib.mkOption {
        type = lib.types.str;
        description = "Stable Tailscale IPv4 address used outside the LAN.";
      };
    };
  };

  connect = pkgs.writeShellApplication {
    name = "peer-connect";
    runtimeInputs = with pkgs; [ coreutils gawk getent iproute2 netcat-openbsd ];
    text = ''
      peer="''${1:?usage: peer-connect PEER PORT}"
      port="''${2:?usage: peer-connect PEER PORT}"
      mode="''${3:-connect}"

      case "$peer" in
        ${lib.concatMapStringsSep "\n" (peer: ''
          ${lib.escapeShellArg peer.name})
            lan_host=${lib.escapeShellArg peer.lanHost}
            tail_address=${lib.escapeShellArg peer.tailscaleAddress}
            ;;
        '') peers}
        *)
          echo "peer-connect: unknown peer: $peer" >&2
          exit 2
          ;;
      esac

      # getent can return the same address several times. Only addresses whose
      # kernel route leaves via a real LAN interface qualify as local.
      mapfile -t addresses < <(getent ahostsv4 "$lan_host" 2>/dev/null \
        | awk '{ print $1 }' | sort -u)
      for address in "''${addresses[@]}"; do
        route=$(ip -4 route get "$address" 2>/dev/null || true)
        case "$route" in
          *" dev tailscale0 "*|*" dev proton"*|*" dev wg"*) continue ;;
        esac
        if nc -z -w ${toString cfg.probeSeconds} "$address" "$port" 2>/dev/null; then
          if [ "$mode" = --probe ]; then
            printf 'lan %s\n' "$address"
            exit 0
          fi
          exec nc "$address" "$port"
        fi
      done

      if [ "$mode" = --probe ]; then
        if nc -z -w ${toString cfg.probeSeconds} "$tail_address" "$port" 2>/dev/null; then
          printf 'tailscale %s\n' "$tail_address"
          exit 0
        fi
        exit 1
      fi
      exec nc "$tail_address" "$port"
    '';
  };

  forwardModule = { name, ... }: {
    options = {
      peer = lib.mkOption { type = lib.types.str; };
      listenPort = lib.mkOption { type = lib.types.port; };
      targetPort = lib.mkOption { type = lib.types.port; };
    };
  };
in
{
  options.local.peerTransport = {
    enable = lib.mkEnableOption "LAN-first peer discovery with a Tailscale fallback";
    probeSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
    };
    peers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule peerModule);
      default = { };
    };
    forwards = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule forwardModule);
      default = { };
      description = "Stable loopback TCP endpoints backed by LAN-first peers.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = connect;
    };
  };

  config = lib.mkIf cfg.enable {
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = true;
      };
    };

    environment.systemPackages = [ connect ];

    systemd.services = lib.mapAttrs' (name: forward:
      let
        connector = pkgs.writeShellScript "peer-forward-${name}-connect" ''
          exec ${connect}/bin/peer-connect ${lib.escapeShellArg forward.peer} ${toString forward.targetPort}
        '';
      in
      lib.nameValuePair "peer-forward-${name}" {
        description = "LAN-first ${name} connection to ${forward.peer}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "tailscaled.service" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.socat}/bin/socat TCP4-LISTEN:${toString forward.listenPort},bind=127.0.0.1,reuseaddr,fork EXEC:${connector}";
          Restart = "always";
          RestartSec = 1;
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
        };
      }
    ) cfg.forwards;

    assertions = lib.mapAttrsToList (_: forward: {
      assertion = builtins.hasAttr forward.peer cfg.peers;
      message = "peer transport forward refers to unknown peer ${forward.peer}";
    }) cfg.forwards;
  };
}

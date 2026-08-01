# Offload builds to a remote builder, waking it first if it is asleep.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.build.client;
  tailscale = lib.getExe config.services.tailscale.package;
  nixDaemonNovpn = import ./nix-daemon-novpn.nix {
    inherit pkgs;
    nixPackage = config.nix.package;
  };

  # Delegates to wake-peer when the builder is a configured peer, so a LUKS
  # unlock happens on the way up.
  wake = pkgs.writeShellApplication {
    name = "builder-wake";
    runtimeInputs = with pkgs; [
      netcat-openbsd
      wol
    ];
    text = ''
      host="''${1:-${cfg.builderHost}}"
      if ${
        if cfg.tailscaleSsh then
          ''${tailscale} ping --timeout="${toString cfg.wake.probeSeconds}s" --c=1 "$host" >/dev/null 2>&1''
        else
          ''nc -z -w "${toString cfg.wake.probeSeconds}" "$host" "${toString cfg.builderPort}" 2>/dev/null''
      }; then
        exit 0
      fi
      ${
        if config.local.wake.peers ? ${cfg.builderHost} then
          ''exec ${config.local.wake.package}/bin/wake-peer "$host"''
        else
          lib.optionalString (cfg.wake.mac != null) ''
            wol ${lib.optionalString (cfg.wake.broadcast != null) "-i ${cfg.wake.broadcast}"} ${cfg.wake.mac}
          ''
      }
      exit 1
    '';
  };

  # nc must not get -w: it caps idle time too, tearing down long builds.
  proxy = pkgs.writeShellScript "builder-proxy" ''
    ${wake}/bin/builder-wake "$1" || exit 1
    exec ${if cfg.tailscaleSsh then "${tailscale} nc" else "${pkgs.netcat-openbsd}/bin/nc"} "$1" "$2"
  '';
in

{
  options.local.build.client = {
    enable = lib.mkEnableOption "distributed builds against a remote builder";

    builderHost = lib.mkOption {
      type = lib.types.str;
      description = "Hostname of the builder, normally its MagicDNS name.";
    };

    builderUser = lib.mkOption {
      type = lib.types.str;
      default = "nixremote";
    };

    builderPort = lib.mkOption {
      type = lib.types.port;
      default = 2222;
    };

    tailscaleSsh = lib.mkEnableOption "Tailscale SSH transport";

    sshKey = lib.mkOption {
      # str, not path: a path literal would copy the key into the store.
      type = lib.types.str;
      default = "/root/.ssh/nixremote";
      description = ''
        Passphrase-less key owned by root: the daemon runs as root and cannot
        prompt for one.
      '';
    };

    maxJobs = lib.mkOption {
      type = lib.types.int;
      default = 4;
    };

    speedFactor = lib.mkOption {
      type = lib.types.int;
      default = 2;
    };

    supportedFeatures = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "big-parallel"
        "kvm"
        "nixos-test"
      ];
    };

    publicHostKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Base64 host key of the builder. Null skips verification.";
    };

    wake = {
      mac = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Builder MAC for Wake-on-LAN. A magic packet is a layer-2 broadcast and
          does not traverse Tailscale, so this only works on the same LAN unless
          something on that LAN relays it.
        '';
      };

      broadcast = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Broadcast address to send the magic packet to.";
      };

      probeSeconds = lib.mkOption {
        type = lib.types.int;
        default = 2;
      };

    };
  };

  config = lib.mkIf cfg.enable {
    nix.distributedBuilds = true;
    nix.settings.builders-use-substitutes = true;

    nix.buildMachines = [
      (
        {
          hostName = "${cfg.builderHost}-builder${lib.optionalString cfg.tailscaleSsh "?remote-program=${nixDaemonNovpn}/bin/nix-daemon-novpn"}";
          sshUser = cfg.builderUser;
          sshKey = if cfg.tailscaleSsh then null else toString cfg.sshKey;
          protocol = "ssh-ng";
          system = pkgs.stdenv.hostPlatform.system;
          inherit (cfg) maxJobs speedFactor supportedFeatures;
        }
        // lib.optionalAttrs (cfg.publicHostKey != null) { inherit (cfg) publicHostKey; }
      )
    ];

    programs.ssh.extraConfig = ''
      Host ${cfg.builderHost}-builder
        HostName ${cfg.builderHost}
        Port ${toString cfg.builderPort}
        User ${cfg.builderUser}
        ${lib.optionalString (!cfg.tailscaleSsh) "IdentityFile ${toString cfg.sshKey}"}
        ${lib.optionalString cfg.tailscaleSsh ''
          # Tailscale authenticates the peer.
          StrictHostKeyChecking no
          UserKnownHostsFile /dev/null
        ''}
        ${lib.optionalString (!cfg.tailscaleSsh) "ConnectTimeout ${toString cfg.wake.probeSeconds}"}
        ServerAliveInterval 30
        ProxyCommand ${proxy} %h %p
    '';

    environment.systemPackages = [ wake ];

    assertions = [
      {
        assertion =
          cfg.tailscaleSsh || (lib.hasPrefix "/" cfg.sshKey && !(lib.hasPrefix builtins.storeDir cfg.sshKey));
        message = "sshKey must be an absolute path outside the world-readable store, not \"${cfg.sshKey}\".";
      }
    ];

    warnings =
      lib.optional (!cfg.tailscaleSsh && cfg.publicHostKey == null)
        "publicHostKey is unset, so the builder is unauthenticated. Get it with: base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub";
  };
}

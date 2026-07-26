# Offload builds to a remote builder, waking it first if it is asleep.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.build.client;

  wake = pkgs.writeShellApplication {
    name = "builder-wake";
    runtimeInputs = with pkgs; [
      netcat-openbsd
      wol
    ];
    text = ''
      host="''${1:-${cfg.builderHost}}"
      if nc -z -w "${toString cfg.wake.probeSeconds}" "$host" 22 2>/dev/null; then
        exit 0
      fi
      ${lib.optionalString (cfg.wake.mac != null) ''
        wol ${lib.optionalString (cfg.wake.broadcast != null) "-i ${cfg.wake.broadcast}"} ${cfg.wake.mac}
      ''}
      exit 1
    '';
  };

  # Fires the magic packet then fails fast, so the first build falls back to
  # local while the builder boots and later ones land remotely.
  proxy = pkgs.writeShellScript "builder-proxy" ''
    ${wake}/bin/builder-wake "$1" || true
    exec ${pkgs.netcat-openbsd}/bin/nc -w "${toString cfg.wake.probeSeconds}" "$1" "$2"
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

    sshKey = lib.mkOption {
      type = lib.types.path;
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
          hostName = cfg.builderHost;
          sshUser = cfg.builderUser;
          sshKey = toString cfg.sshKey;
          protocol = "ssh-ng";
          system = pkgs.stdenv.hostPlatform.system;
          inherit (cfg) maxJobs speedFactor supportedFeatures;
        }
        // lib.optionalAttrs (cfg.publicHostKey != null) { inherit (cfg) publicHostKey; }
      )
    ];

    programs.ssh.extraConfig = ''
      Host ${cfg.builderHost}
        User ${cfg.builderUser}
        IdentityFile ${toString cfg.sshKey}
        ConnectTimeout ${toString cfg.wake.probeSeconds}
        ServerAliveInterval 30
        ${lib.optionalString (cfg.wake.mac != null) "ProxyCommand ${proxy} %h %p"}
    '';

    environment.systemPackages = [ wake ];
  };
}

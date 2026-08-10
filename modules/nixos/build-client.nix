# Offload builds to remote builders, waking them first if they are asleep.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.build.client;
  tailscale = lib.getExe config.services.tailscale.package;

  builders = lib.attrValues cfg.builders;

  probe =
    b:
    if b.tailscaleSsh then
      ''${tailscale} ping --timeout="${toString b.wake.probeSeconds}s" --c=1 "$host" >/dev/null 2>&1''
    else
      ''nc -z -w "${toString b.wake.probeSeconds}" "$host" "${toString b.port}" 2>/dev/null'';

  # Delegates to wake-peer when the builder is a configured peer, so a LUKS
  # unlock happens on the way up.
  rouse =
    b:
    if config.local.wake.peers ? ${b.host} then
      ''exec ${config.local.wake.package}/bin/wake-peer "$host"''
    else
      lib.optionalString (b.wake.mac != null) ''
        wol ${lib.optionalString (b.wake.broadcast != null) "-i ${b.wake.broadcast}"} ${b.wake.mac}
      '';

  wake = pkgs.writeShellApplication {
    name = "builder-wake";
    runtimeInputs = with pkgs; [
      netcat-openbsd
      wol
    ];
    text = ''
      host="''${1:?usage: builder-wake HOST}"
      case "$host" in
        ${lib.concatMapStringsSep "\n" (b: ''
          ${b.host})
            if ${probe b}; then
              exit 0
            fi
            ${rouse b}
            exit 1 ;;
        '') builders}
        *)
          echo "no builder called $host" >&2
          exit 2 ;;
      esac
    '';
  };

  # nc must not get -w: it caps idle time too, tearing down long builds.
  proxy = pkgs.writeShellScript "builder-proxy" ''
    ${lib.getExe wake} "$1" || exit 1
    case "$1" in
      ${lib.concatMapStringsSep "\n" (b: ''
        ${b.host})
          exec ${if b.tailscaleSsh then "${tailscale} nc" else "${pkgs.netcat-openbsd}/bin/nc"} "$1" "$2" ;;
      '') builders}
    esac
    exit 1
  '';

  builderModule =
    { name, ... }:
    {
      options = {
        host = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Hostname of the builder, normally its MagicDNS name.";
        };

        user = lib.mkOption {
          type = lib.types.str;
          default = "nixremote";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 2222;
        };

        tailscaleSsh = lib.mkEnableOption "Tailscale SSH transport";

        sshKey = lib.mkOption {
          # str, not path: a path literal would copy the key into the store.
          type = lib.types.str;
          default = "/root/.ssh/nixremote";
          description = "Passphrase-less key owned by root; the daemon cannot prompt.";
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

        remoteProgram = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "/run/current-system/sw/bin/nix-daemon-novpn";
          description = "Daemon path, resolved on the builder, not here.";
        };

        publicHostKey = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Base64 host key of the builder. Null skips verification.";
        };

        systems = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ pkgs.stdenv.hostPlatform.system ];
          description = "Systems to request from this builder.";
        };

        wake = {
          mac = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            # A magic packet is a layer-2 broadcast and does not traverse
            # Tailscale, so this only works on the same LAN unless something
            # on that LAN relays it.
            description = "Builder MAC for Wake-on-LAN.";
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
    };
in

{
  options.local.build.client = {
    enable = lib.mkEnableOption "distributed builds against remote builders";

    builders = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule builderModule);
      default = { };
      description = "Builders to offload to, keyed by hostname.";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.distributedBuilds = true;
    nix.settings.builders-use-substitutes = true;
    nix.settings.builders = "@/etc/nix/machines";

    nix.buildMachines = map (
      b:
      {
        hostName = "${b.host}-builder${
          lib.optionalString (b.remoteProgram != null) "?remote-program=${b.remoteProgram}"
        }";
        sshUser = b.user;
        sshKey = if b.tailscaleSsh then null else toString b.sshKey;
        protocol = "ssh-ng";
        inherit (b)
          systems
          maxJobs
          speedFactor
          supportedFeatures
          ;
      }
      // lib.optionalAttrs (b.publicHostKey != null) { inherit (b) publicHostKey; }
    ) builders;

    programs.ssh.extraConfig = lib.concatMapStrings (b: ''
      Host ${b.host}-builder
        HostName ${b.host}
        Port ${toString b.port}
        User ${b.user}
        ${lib.optionalString (!b.tailscaleSsh) "IdentityFile ${toString b.sshKey}"}
        ${lib.optionalString b.tailscaleSsh ''
          # Tailscale authenticates the peer.
          StrictHostKeyChecking no
          UserKnownHostsFile /dev/null
        ''}
        ${lib.optionalString (!b.tailscaleSsh) "ConnectTimeout ${toString b.wake.probeSeconds}"}
        ServerAliveInterval 30
        ProxyCommand ${proxy} %h %p
    '') builders;

    environment.systemPackages = [ wake ];

    assertions = map (b: {
      assertion =
        b.tailscaleSsh || (lib.hasPrefix "/" b.sshKey && !(lib.hasPrefix builtins.storeDir b.sshKey));
      message = "sshKey for ${b.host} must be an absolute path outside the world-readable store, not \"${b.sshKey}\".";
    }) builders;

    warnings = lib.concatMap (
      b:
      lib.optional (!b.tailscaleSsh && b.publicHostKey == null)
        "publicHostKey for ${b.host} is unset, so the builder is unauthenticated. Get it with: base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub"
    ) builders;
  };
}

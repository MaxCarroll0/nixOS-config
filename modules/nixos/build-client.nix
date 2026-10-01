# Offload builds to remote builders, waking them first if they are asleep.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.build.client;
  builders = lib.attrValues cfg.builders;
  peerConnect = "${config.local.peerTransport.package}/bin/peer-connect";

  stateDir = "/run/nix-offload";
  machinesFile = "${stateDir}/machines";

  probe =
    b: ''${peerConnect} ${lib.escapeShellArg b.peer} "${toString b.port}" --probe >/dev/null 2>&1'';

  # Delegates to wake-peer when the builder is a configured peer, so a LUKS
  # unlock happens on the way up.
  rouse =
    b:
    if config.local.wake.peers ? ${b.wakePeer} then
      "exec ${config.local.wake.package}/bin/wake-peer ${b.wakePeer}"
    else
      lib.optionalString (b.wake.mac != null) ''
        wol ${lib.optionalString (b.wake.broadcast != null) "-i ${b.wake.broadcast}"} ${b.wake.mac}
      '';

  sendOnly =
    b:
    if config.local.wake.peers ? ${b.wakePeer} then
      "exec ${config.local.wake.package}/bin/wake-peer --send-only ${b.wakePeer}"
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
      async=0
      if [ "''${1:-}" = --async ]; then
        async=1
        shift
      fi

      host="''${1:?usage: builder-wake [--async] HOST}"
      case "$host" in
        ${lib.concatMapStringsSep "\n" (b: ''
          ${b.host})
            if ${probe b}; then
              exit 0
            fi
            if [ "$async" = 1 ]; then
              ${sendOnly b}
              exit 1
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

  lease = pkgs.writeShellApplication {
    name = "builder-lease";
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      host="''${1:?usage: builder-lease HOST}"
      case "$host" in
        ${lib.concatMapStringsSep "\n" (b: ''
          ${b.host})
            exec ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 \
              -o StrictHostKeyChecking=accept-new \
              -o UserKnownHostsFile=${leaseKnownHosts} \
              -o ProxyCommand="${peerConnect} ${lib.escapeShellArg b.peer} ${toString b.port}" \
              -i ${toString b.sshKey} -l ${cfg.leaseUser} "$host" \
              ${cfg.leaseCommand} --take ${cfg.leaseName} --why nix-offload --for ${cfg.leaseDuration} ;;
        '') builders}
        *)
          echo "no builder called $host" >&2
          exit 2 ;;
      esac
    '';
  };

  leaseKnownHosts = "/root/.ssh/known_hosts.builders";

  offload = pkgs.writeShellApplication {
    name = "nix-build-offload";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec python3 ${./build-offload.py} ${offloadConfig} "$@"
    '';
  };

  offloadConfig = pkgs.writeText "nix-build-offload.json" (
    builtins.toJSON {
      hook = [
        "${config.nix.package}/bin/nix"
        "__build-remote"
      ];
      graceSeconds = cfg.localGraceMinutes * 60;
      probeSeconds = 5;
      wakeSeconds = 60;
      leaseSeconds = 300;
      source = "/etc/nix/machines";
      managed = "@${machinesFile}";
      builders = map (b: {
        inherit (b) host systems;
        features = b.supportedFeatures;
        uri = "ssh-ng://${b.user}@${b.host}-builder";
        probe = [
          peerConnect
          b.peer
          (toString b.port)
          "--probe"
        ];
        wake = [
          (lib.getExe wake)
          "--async"
          b.host
        ];
        lease = [
          (lib.getExe lease)
          b.host
        ];
      }) builders;
    }
  );

  # nc must not get -w: it caps idle time too, tearing down long builds.
  proxy = pkgs.writeShellScript "builder-proxy" ''
    ${lib.getExe wake} "$1" || exit 1
    case "$1" in
      ${lib.concatMapStringsSep "\n" (b: ''
        ${b.host})
          exec ${peerConnect} ${lib.escapeShellArg b.peer} "$2" ;;
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

        peer = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "local.peerTransport.peers entry used to reach this builder.";
        };

        wakePeer = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "local.wake.peers entry to rouse this builder with.";
        };

        user = lib.mkOption {
          type = lib.types.str;
          default = "nixremote";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 2222;
        };

        sshKey = lib.mkOption {
          # str, not path: a path literal would copy the key into the store.
          type = lib.types.str;
          default = "/root/.ssh/nixremote";
          description = "Passphrase-less key owned by root; the daemon cannot prompt.";
        };

        cipher = lib.mkOption {
          type = lib.types.str;
          default = "aes128-gcm@openssh.com";
          description = "Fast authenticated-encryption cipher for the bulk Nix SSH stream.";
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
          description = "OpenSSH ed25519 public-key body pinned for the builder alias.";
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

        connectTimeoutSeconds = lib.mkOption {
          type = lib.types.int;
          default = 180;
          description = "ssh ConnectTimeout; must outlast a cold boot and LUKS unlock.";
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

    localGraceMinutes = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Minutes of building here before the rest goes to a builder.";
    };

    leaseUser = lib.mkOption {
      type = lib.types.str;
      default = "max";
      description = "Account on the builder allowed to hold it awake.";
    };

    leaseCommand = lib.mkOption {
      type = lib.types.str;
      default = "/run/current-system/sw/bin/keep-awake";
      description = "keep-awake path, resolved on the builder, not here.";
    };

    leaseName = lib.mkOption {
      type = lib.types.str;
      default = "nix-offload";
      description = "Name of the keep-awake lease held while offloading.";
    };

    leaseDuration = lib.mkOption {
      type = lib.types.str;
      default = "20m";
      description = "Lease lifetime; expires on its own if this host dies.";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.distributedBuilds = true;
    nix.settings.builders-use-substitutes = true;
    nix.settings.builders = "@${machinesFile}";
    nix.settings.build-hook = "${offload}/bin/nix-build-offload";

    environment.etc."nix/offload-builders".text = lib.concatMapStrings (b: "${b.host}\n") builders;

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
      "f ${machinesFile} 0644 root root -"
    ];

    nix.buildMachines = map (b: {
      hostName = "${b.host}-builder${
        lib.optionalString (b.remoteProgram != null) "?remote-program=${b.remoteProgram}"
      }";
      sshUser = b.user;
      sshKey = toString b.sshKey;
      protocol = "ssh-ng";
      inherit (b)
        systems
        maxJobs
        speedFactor
        supportedFeatures
        ;
    }) builders;

    # Nix's machine-file publicHostKey handling does not cooperate with the
    # ProxyCommand alias. Pin that exact alias in OpenSSH's system known-hosts
    # file instead; Nix then uses normal strict host-key verification.
    programs.ssh.knownHosts = lib.listToAttrs (
      lib.concatMap (
        b:
        lib.optional (b.publicHostKey != null) {
          name = "${b.host}-builder";
          value = {
            publicKey = "ssh-ed25519 ${b.publicHostKey}";
            hostNames = [
              "${b.host}-builder"
              b.host
              "[${b.host}]:${toString b.port}"
            ];
          };
        }
      ) builders
    );

    programs.ssh.extraConfig = lib.concatMapStrings (b: ''
      Host ${b.host}-builder
        HostName ${b.host}
        Port ${toString b.port}
        # nix pins publicHostKey under the alias, so verification must use it
        # too, not the rewritten [${b.host}]:${toString b.port}.
        HostKeyAlias ${b.host}-builder
        User ${b.user}
        IdentityFile ${toString b.sshKey}
        IdentitiesOnly yes
        ConnectTimeout ${toString b.connectTimeoutSeconds}
        Compression no
        Ciphers ${b.cipher}
        ServerAliveInterval 30
        ProxyCommand ${proxy} %h %p
    '') builders;

    environment.systemPackages = [
      wake
      lease
      offload
    ];

    assertions = lib.concatMap (b: [
      {
        assertion =
          builtins.hasAttr b.peer config.local.peerTransport.peers
          && lib.hasPrefix "/" b.sshKey
          && !(lib.hasPrefix builtins.storeDir b.sshKey);
        message = "sshKey for ${b.host} must be an absolute path outside the world-readable store, not \"${b.sshKey}\".";
      }
      {
        # knownHosts prepends the key type, so this must be the bare body:
        # a whole .pub line or its base64 lands in known_hosts malformed.
        assertion = b.publicHostKey == null || lib.hasPrefix "AAAAC3NzaC1lZDI1NTE5" b.publicHostKey;
        message = "publicHostKey for ${b.host} must be the bare ed25519 key body: awk '{print $2}' /etc/ssh/ssh_host_ed25519_key.pub";
      }
    ]) builders;

    warnings = lib.concatMap (
      b:
      lib.optional (b.publicHostKey == null)
        "publicHostKey for ${b.host} is unset, so the builder is unauthenticated. Get it with: awk '{print $2}' /etc/ssh/ssh_host_ed25519_key.pub"
    ) builders;
  };
}

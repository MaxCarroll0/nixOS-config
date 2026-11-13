# Wake a peer over Wake-on-LAN and unlock its encrypted root from initrd.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.wake;

  peerCase = name: p: /* bash */ ''
    ${name})
      mac="${toString (p.mac or "")}"
      bcast="${toString (p.broadcast or "")}"
      unlockPort="${toString p.unlockPort}"
      passFile="${toString (if p.passphraseFile == null then "" else p.passphraseFile)}"
      timeout="${toString p.timeoutSeconds}"
      lanHost="${toString (if p.address == null then "" else p.address)}"
      ;;
  '';

  wakePeer = pkgs.writeShellApplication {
    name = "wake-peer";
    runtimeInputs = with pkgs; [
      netcat-openbsd
      iputils
      wol
      openssh
      coreutils
      gnugrep
      iproute2
      tailscale
    ];
    text = builtins.replaceStrings [ "@peers@" "@relays@" ] [
      (lib.concatStrings (lib.mapAttrsToList peerCase cfg.peers))
      (lib.escapeShellArgs (lib.mapAttrsToList (name: address: "${name}=${address}") cfg.relays))
    ] (builtins.readFile ./wake-peer.sh);
  };
in

{
  options.local.wake = {
    peers = lib.mkOption {
      default = { };
      description = "Hosts this machine may wake and unlock.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            mac = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            broadcast = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional extra broadcast address; local ones are derived at runtime.";
            };

            address = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional LAN address; only needed for the initrd unlock probe.";
            };
            unlockPort = lib.mkOption {
              type = lib.types.port;
              default = 2222;
            };
            passphraseFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Set only when this host performs the unlock itself.";
            };
            timeoutSeconds = lib.mkOption {
              type = lib.types.int;
              default = 90;
            };
          };
        }
      );
    };

    relays = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Hosts that may be asked to send the magic packet on this host's behalf.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = wakePeer;
      readOnly = true;
    };
  };

  config = lib.mkIf (cfg.peers != { }) {
    environment.systemPackages = [ wakePeer ];
  };
}

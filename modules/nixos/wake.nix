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
      lanPort="${toString p.port}"
      ;;
  '';

  wakePeer = pkgs.writeShellApplication {
    name = "wake-peer";
    runtimeInputs = with pkgs; [
      netcat-openbsd
      wol
      openssh
      coreutils
    ];
    text = ''
      host="''${1:?usage: wake-peer <host>}"
      probe() { nc -z -w 2 "$1" "$2" 2>/dev/null; }

      mac=""; bcast=""; unlockPort=""; passFile=""; timeout=90
      lanHost=""; lanPort=22
      case "$host" in
        ${lib.concatStrings (lib.mapAttrsToList peerCase cfg.peers)}
        *) ;;
      esac

      ready() {
        if [ -n "$lanHost" ]; then
          probe "$lanHost" "$lanPort"
        else
          probe "$host" 22
        fi
      }

      ready && exit 0

      if [ -n "$mac" ]; then
        if [ -n "$bcast" ]; then wol -i "$bcast" "$mac"; else wol "$mac"; fi
      fi

      deadline=$(( $(date +%s) + timeout ))

      if [ -n "$passFile" ]; then
        while [ "$(date +%s)" -lt "$deadline" ]; do
          if probe "$host" "$unlockPort"; then
            if [ -r "$passFile" ]; then
              ssh -p "$unlockPort" -o StrictHostKeyChecking=accept-new \
                  -o ConnectTimeout=5 "root@$host" < "$passFile" || true
            else
              echo "no passphrase at $passFile" >&2
            fi
            break
          fi
          sleep 2
        done
      fi

      while [ "$(date +%s)" -lt "$deadline" ]; do
        ready && exit 0
        sleep 0.5
      done
      exit 1
    '';
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
            };

            address = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "LAN address, reachable well before the tailnet name is.";
            };

            port = lib.mkOption {
              type = lib.types.port;
              default = 22;
              description = "Port on address that proves the peer is up.";
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

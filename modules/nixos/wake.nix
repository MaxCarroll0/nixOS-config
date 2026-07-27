# Wake a peer over Wake-on-LAN and unlock its encrypted root from initrd.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.wake;

  peerCase = name: p: ''
    ${name})
      mac="${toString (p.mac or "")}"
      bcast="${toString (p.broadcast or "")}"
      unlockPort="${toString p.unlockPort}"
      passFile="${p.passphraseFile}"
      timeout="${toString p.timeoutSeconds}"
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
      case "$host" in
        ${lib.concatStrings (lib.mapAttrsToList peerCase cfg.peers)}
        *) ;;
      esac

      probe "$host" 22 && exit 0

      if [ -n "$mac" ]; then
        if [ -n "$bcast" ]; then wol -i "$bcast" "$mac"; else wol "$mac"; fi
      fi

      [ -n "$unlockPort" ] || exit 1

      deadline=$(( $(date +%s) + timeout ))
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

      while [ "$(date +%s)" -lt "$deadline" ]; do
        probe "$host" 22 && exit 0
        sleep 2
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
            unlockPort = lib.mkOption {
              type = lib.types.port;
              default = 2222;
            };
            passphraseFile = lib.mkOption {
              type = lib.types.str;
              description = "Root-only; protected at rest by this host's own FDE.";
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

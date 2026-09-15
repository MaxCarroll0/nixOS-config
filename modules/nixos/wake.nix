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
    text = ''
      host="''${1:?usage: wake-peer <host>}"
      probe() { nc -z -w 2 "$1" "$2" 2>/dev/null; }

      mac=""; bcast=""; unlockPort=""; passFile=""; timeout=90
      lanHost=""
      case "$host" in
        ${lib.concatStrings (lib.mapAttrsToList peerCase cfg.peers)}
        *) ;;
      esac

      ready() {
        if [ -n "$lanHost" ] && ping -c 1 -W 1 "$lanHost" >/dev/null 2>&1; then
          return 0
        fi
        if tailscale ping -c 1 --timeout 2s --until-direct=false "$host" >/dev/null 2>&1; then
          return 0
        fi
        probe "$host" 22
      }

      send_magic() {
        [ -n "$mac" ] || return 0
        for target in $bcast $(ip -4 -oneline address show scope global \
              | grep -oE 'brd [0-9.]+' | cut -d ' ' -f 2 | sort -u) 255.255.255.255; do
          wol -i "$target" "$mac" >/dev/null 2>&1 || true
        done
      }

      ready && exit 0

      send_magic
      resend=$(( $(date +%s) + 20 ))

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
        if [ "$(date +%s)" -ge "$resend" ]; then
          send_magic
          resend=$(( $(date +%s) + 20 ))
        fi
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

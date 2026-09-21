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
      sendOnly=0
      if [ "''${1:-}" = --send-only ]; then
        sendOnly=1
        shift
      fi

      host="''${1:?usage: wake-peer [--send-only] <host>}"
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

      relayDir="''${XDG_CACHE_HOME:-''${HOME:-/tmp}/.cache}/wake-peer"
      relayHint="$relayDir/$host.relay"

      # A relay on the wrong segment broadcasts harmlessly, so no host needs to know
      # which LAN the sleeper is on.
      delegate() {
        local sent=0 relay candidate hinted="" seen=""
        local -a candidates=()

        if [ -r "$relayHint" ]; then
          hinted="$(cat "$relayHint")"
          [ -n "$hinted" ] && candidates+=("$hinted")
        fi
        candidates+=(${
          lib.escapeShellArgs (lib.mapAttrsToList (name: address: "${name}=${address}") cfg.relays)
        })

        for candidate in "''${candidates[@]}"; do
          relay="''${candidate#*=}"
          [ "''${candidate%%=*}" = "$host" ] && continue
          case " $seen " in *" $relay "*) continue ;; esac
          seen="$seen $relay"

          tailscale ping -c 1 --timeout 3s --until-direct=false "$relay" >/dev/null 2>&1 || continue
          # Bounded: a relay still running a wake-peer without --send-only would
          # otherwise poll for a host named "--send-only" until its own deadline.
          if timeout 10 ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                 "$relay" wake-peer --send-only "$host" >/dev/null 2>&1; then
            sent=1
            if [ "$relay" != "$hinted" ] && mkdir -p "$relayDir" 2>/dev/null; then
              printf '%s\n' "$relay" > "$relayHint" 2>/dev/null || true
            fi
          fi
        done

        [ "$sent" = 1 ]
      }

      if [ "$sendOnly" = 1 ]; then
        send_magic
        exit 0
      fi

      ready && exit 0

      send_magic
      delegate || true
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
          delegate || true
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

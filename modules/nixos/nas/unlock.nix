# NAS unlocking: the array never unlocks at boot; the laptop drives it over Tailscale SSH.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas;
  ucfg = cfg.unlock;

  disks = scfg: lib.mapAttrsToList (name: d: "${name}=${d.device}") cfg.storage.dataDisks;

  serverUnlock = pkgs.writeShellApplication {
    name = "nas-unlock-local";
    runtimeInputs = [
      pkgs.cryptsetup
      pkgs.util-linux
      pkgs.systemd
    ];
    text = ''
      key=$(cat)
      [ -n "$key" ] || { echo "no key on stdin" >&2; exit 2; }

      opened=0
      for spec in ${lib.escapeShellArgs (disks cfg.storage)} ${lib.escapeShellArg "parity=${ucfg.parityDevice}"}; do
        name=''${spec%%=*}
        dev=''${spec#*=}
        [ -b "$dev" ] || continue
        if [ -e "/dev/mapper/nas-$name" ]; then
          opened=$((opened + 1))
          continue
        fi
        if printf '%s' "$key" | cryptsetup luksOpen --key-file=- "$dev" "nas-$name"; then
          opened=$((opened + 1))
        else
          echo "failed to unlock $name" >&2
        fi
      done
      unset key

      for m in ${
        lib.escapeShellArgs (
          lib.mapAttrsToList (n: _: "${cfg.storage.diskRoot}/${n}") cfg.storage.dataDisks
        )
      }; do
        mountpoint -q "$m" || mount "$m" || true
      done
      systemctl start "$(systemd-escape -p --suffix=mount ${cfg.dataRoot})" || true
      systemctl start ${ucfg.target} || true

      mounted=0
      for m in ${
        lib.escapeShellArgs (
          lib.mapAttrsToList (n: _: "${cfg.storage.diskRoot}/${n}") cfg.storage.dataDisks
        )
      }; do
        mountpoint -q "$m" && mounted=$((mounted + 1))
      done

      echo "unlocked=$opened mounted=$mounted"
      [ "$mounted" -gt 0 ]
    '';
  };

  serverLock = pkgs.writeShellApplication {
    name = "nas-lock-local";
    runtimeInputs = [
      pkgs.cryptsetup
      pkgs.systemd
    ];
    text = ''
      systemctl stop ${ucfg.target} || true
      for name in ${lib.escapeShellArgs (lib.attrNames cfg.storage.dataDisks)} parity; do
        [ -e "/dev/mapper/nas-$name" ] && cryptsetup luksClose "nas-$name" || true
      done
      echo "locked"
    '';
  };

  clientUnlock = pkgs.writeShellApplication {
    name = "nas-unlock";
    runtimeInputs = [
      pkgs.openssh
      pkgs.libnotify
    ];
    text = ''
      key=${ucfg.keyFile}
      [ -r "$key" ] || { echo "cannot read $key" >&2; exit 1; }

      if out=$(ssh -o ConnectTimeout=10 ${ucfg.host} "sudo nas-unlock-local" < "$key" 2>&1); then
        notify-send "NAS unlocked" "$out" 2>/dev/null || true
        echo "$out"
      else
        notify-send -u critical "NAS unlock failed" "$out" 2>/dev/null || true
        echo "$out" >&2
        exit 1
      fi
    '';
  };

  clientLock = pkgs.writeShellApplication {
    name = "nas-lock";
    runtimeInputs = [
      pkgs.openssh
      pkgs.libnotify
    ];
    text = ''
      if out=$(ssh -o ConnectTimeout=10 ${ucfg.host} "sudo nas-lock-local" 2>&1); then
        notify-send "NAS locked" "$out" 2>/dev/null || true
        echo "$out"
      else
        notify-send -u critical "NAS lock failed" "$out" 2>/dev/null || true
        echo "$out" >&2
        exit 1
      fi
    '';
  };
in

{
  options.local.nas.unlock = {
    server = lib.mkEnableOption "the pi side of manual unlocking";
    client = lib.mkEnableOption "the laptop side, nas-unlock and nas-lock";

    host = lib.mkOption {
      type = lib.types.str;
      default = "pi";
      description = "Tailscale name of the NAS host.";
    };

    parityDevice = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Parity disk, unlocked alongside the data disks.";
    };

    target = lib.mkOption {
      type = lib.types.str;
      default = "nas.target";
      description = "Unit started once the disks are open.";
    };

    keyFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/nas-luks-key";
      description = "Passphrase on the client, provisioned by sops and readable by the operator.";
    };

    allowUser = lib.mkOption {
      type = lib.types.str;
      default = "max";
      description = "User permitted to run the unlock and lock units without a password.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && ucfg.server) {
      environment.systemPackages = [
        serverUnlock
        serverLock
      ];

      security.sudo.extraRules = [
        {
          users = [ ucfg.allowUser ];
          commands = [
            {
              command = "/run/current-system/sw/bin/nas-unlock-local";
              options = [ "NOPASSWD" ];
            }
            {
              command = "/run/current-system/sw/bin/nas-lock-local";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];

      systemd.targets.nas = {
        description = "NAS shares, started once the array is unlocked";
        wantedBy = [ ];
      };
    })

    (lib.mkIf ucfg.client {
      environment.systemPackages = [
        clientUnlock
        clientLock
      ];
    })
  ];
}

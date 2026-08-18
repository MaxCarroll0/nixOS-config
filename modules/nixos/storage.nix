# Keep spinning disks asleep until something actually reads them.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.storage;

  enforceDiskIdle = pkgs.writeShellApplication {
    name = "enforce-disk-idle";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.hdparm
      pkgs.jq
      pkgs.smartmontools
    ];
    text = ''
      now=$(date +%s)
      for block in /sys/block/sd[a-z]; do
        [ -e "$block/device" ] || continue
        [ "$(cat "$block/queue/rotational" 2>/dev/null || echo 0)" = 1 ] || continue
        device=''${block##*/}
        io=$(awk -v d="$device" '$3 == d { print $6 + $10 }' /proc/diskstats)
        [ -n "$io" ] || continue
        state="/var/lib/disk-spindown/$device"
        previous=""
        idle_since=$now
        last_standby=0
        if [ -s "$state" ]; then
          read -r previous idle_since last_standby < "$state" || true
        fi
        case "$idle_since" in "" | *[!0-9]*) idle_since=$now ;; esac
        case "$last_standby" in "" | *[!0-9]*) last_standby=0 ;; esac
        if [ "$io" != "$previous" ]; then
          idle_since=$now
        fi
        if [ "$((now - idle_since))" -ge ${toString (cfg.spinDownRotational.idleMinutes * 60)} ] \
          && [ "$((now - last_standby))" -ge ${toString (cfg.spinDownRotational.idleMinutes * 60)} ]; then
          report=$(smartctl -n standby -j -c "/dev/$device" 2>/dev/null || true)
          if ! printf '%s' "$report" \
            | jq -e '(.ata_smart_data.self_test.status.remaining_percent // 0) > 0' >/dev/null; then
            if hdparm -y "/dev/$device" >/dev/null; then
              last_standby=$now
            fi
          fi
        fi
        printf '%s %s %s\n' "$io" "$idle_since" "$last_standby" > "$state"
      done
    '';
  };
in

{
  options.local.storage = {
    spinDownRotational = {
      enable = lib.mkEnableOption "idle spin-down for rotational disks";

      apmLevel = lib.mkOption {
        type = lib.types.int;
        default = 254;
        description = "hdparm -B value applied to rotational disks.";
      };

      idleMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = "Minutes without block I/O before userspace forces standby.";
      };
    };

    lazyMounts = lib.mkOption {
      default = { };
      description = "Filesystems mounted on first access rather than at boot.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            device = lib.mkOption { type = lib.types.str; };
            fsType = lib.mkOption {
              type = lib.types.str;
              default = "ext4";
            };
            options = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            idleMinutes = lib.mkOption {
              type = lib.types.int;
              default = 10;
              description = "Unmount after this long idle, letting the disk spin down.";
            };
          };
        }
      );
    };

    luksVaults = lib.mkOption {
      default = { };
      description = "LUKS volumes that unlock on cd into their mount point and lock again on cd out.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              device = lib.mkOption {
                type = lib.types.str;
                description = "Path to the LUKS partition, e.g. /dev/disk/by-uuid/....";
              };
              mapperName = lib.mkOption {
                type = lib.types.str;
                default = name;
              };
              mountPoint = lib.mkOption { type = lib.types.str; };
              users = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ "max" ];
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.spinDownRotational.enable {
      services.udev.extraRules = ''
        ACTION=="add", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", RUN+="${pkgs.hdparm}/bin/hdparm -B ${toString cfg.spinDownRotational.apmLevel} -S 0 /dev/%k"
      '';

      environment.systemPackages = [ pkgs.hdparm ];

      systemd.services.enforce-disk-idle = {
        description = "Force rotational disks into standby after their idle deadline";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe enforceDiskIdle;
          StateDirectory = "disk-spindown";
        };
      };

      systemd.timers.enforce-disk-idle = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1m";
          OnUnitActiveSec = "1m";
          AccuracySec = "10s";
        };
      };
    })

    (lib.mkIf (cfg.lazyMounts != { }) {
      fileSystems = lib.mapAttrs (_: m: {
        inherit (m) device fsType;
        options = m.options ++ [
          "noauto"
          "x-systemd.automount"
          "x-systemd.idle-timeout=${toString (m.idleMinutes * 60)}"
          "x-systemd.device-timeout=10s"
        ];
      }) cfg.lazyMounts;
    })

    (lib.mkIf (cfg.luksVaults != { }) {
      environment.systemPackages = [ pkgs.cryptsetup ];

      systemd.tmpfiles.rules = lib.mapAttrsToList (
        _: v: "d ${v.mountPoint} 0700 root root - -"
      ) cfg.luksVaults;

      security.sudo.extraRules = lib.mapAttrsToList (_: v: {
        users = v.users;
        commands = [
          {
            command = "${pkgs.cryptsetup}/bin/cryptsetup luksOpen ${v.device} ${v.mapperName}";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.cryptsetup}/bin/cryptsetup luksClose ${v.mapperName}";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.util-linux}/bin/mount /dev/mapper/${v.mapperName} ${v.mountPoint}";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.util-linux}/bin/umount ${v.mountPoint}";
            options = [ "NOPASSWD" ];
          }
        ];
      }) cfg.luksVaults;

      programs.bash.interactiveShellInit =
        lib.concatStrings (
          lib.mapAttrsToList (name: v: ''
            __vault_${name}_open() {
              sudo -n ${pkgs.cryptsetup}/bin/cryptsetup luksOpen ${v.device} ${v.mapperName} \
                && sudo -n ${pkgs.util-linux}/bin/mount /dev/mapper/${v.mapperName} ${v.mountPoint}
            }
            __vault_${name}_close() {
              sudo -n ${pkgs.util-linux}/bin/umount ${v.mountPoint} >/dev/null 2>&1
              sudo -n ${pkgs.cryptsetup}/bin/cryptsetup luksClose ${v.mapperName} >/dev/null 2>&1
            }
          '') cfg.luksVaults
        )
        + ''
          cd() {
            local target dest
            target="''${1:-$HOME}"
            if [[ "$target" == "-" ]]; then
              dest="''${OLDPWD:-$PWD}"
            else
              dest="$(realpath -m -- "$target" 2>/dev/null || printf '%s' "$target")"
            fi
        ''
        + lib.concatStrings (
          lib.mapAttrsToList (name: v: ''
            if [[ "$PWD" == "${v.mountPoint}" || "$PWD" == "${v.mountPoint}"/* ]] \
              && [[ "$dest" != "${v.mountPoint}" && "$dest" != "${v.mountPoint}"/* ]]; then
              builtin cd "$@" && __vault_${name}_close
              return
            fi
          '') cfg.luksVaults
        )
        + lib.concatStrings (
          lib.mapAttrsToList (name: v: ''
            if [[ "$dest" == "${v.mountPoint}" || "$dest" == "${v.mountPoint}"/* ]] && ! mountpoint -q "${v.mountPoint}"; then
              __vault_${name}_open || return 1
            fi
          '') cfg.luksVaults
        )
        + ''
            builtin cd "$@"
          }
        '';
    })

    {
      warnings =
        lib.optional config.services.smartd.enable "services.smartd polls disks and will spin them up; add '-n standby' to its device options."
        ++ lib.optional (config.services.prometheus.exporters.smartctl.enable or false
        ) "the smartctl exporter polls disks and will spin them up."
        ++
          lib.optional
            (
              cfg.spinDownRotational.enable
              && builtins.elem "hwmon" (config.services.prometheus.exporters.node.enabledCollectors or [ ])
              && (config.local.monitoring.exporter.hwmonChipExclude or "") == ""
              && (config.local.monitoring.exporter.scrapeCadenceOverrides or { }) == { }
            )
            "node_exporter's hwmon collector reads drivetemp on every scrape, which resets the spin-down timer; add a local.monitoring.exporter.scrapeCadenceOverrides entry.";
    }
  ];
}

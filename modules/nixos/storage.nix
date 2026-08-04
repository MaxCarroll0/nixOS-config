# Keep spinning disks asleep until something actually reads them.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.storage;
in

{
  options.local.storage = {
    spinDownRotational = {
      enable = lib.mkEnableOption "idle spin-down for rotational disks";

      # hdparm -S: 1..240 are 5s units, so 120 is 10 minutes.
      standbyValue = lib.mkOption {
        type = lib.types.int;
        default = 120;
        description = "hdparm -S value applied to rotational disks.";
      };

      apmLevel = lib.mkOption {
        type = lib.types.int;
        default = 127;
        description = "hdparm -B value; below 128 permits spin-down.";
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
      # queue/rotational tells HDDs from SSDs, so no device list is needed.
      services.udev.extraRules = ''
        ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", RUN+="${pkgs.hdparm}/bin/hdparm -B ${toString cfg.spinDownRotational.apmLevel} -S ${toString cfg.spinDownRotational.standbyValue} /dev/%k"
      '';

      environment.systemPackages = [ pkgs.hdparm ];
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
        ) "the smartctl exporter polls disks and will spin them up.";
    }
  ];
}

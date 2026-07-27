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

    {
      warnings =
        lib.optional config.services.smartd.enable "services.smartd polls disks and will spin them up; add '-n standby' to its device options."
        ++ lib.optional (config.services.prometheus.exporters.smartctl.enable or false
        ) "the smartctl exporter polls disks and will spin them up.";
    }
  ];
}

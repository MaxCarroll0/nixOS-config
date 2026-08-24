# Keeps the last generation that booted successfully bootable and never collectable.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.lastGoodBoot;

  bootMount = config.boot.loader.efi.efiSysMountPoint;
  bootDevice = config.fileSystems.${bootMount}.device;
  bootUuid = lib.removePrefix "/dev/disk/by-uuid/" bootDevice;

  payloadDir = "${bootMount}/${cfg.directory}";
  menuFile = "${bootMount}/grub/${cfg.directory}.cfg";
  gcRoot = "/nix/var/nix/gcroots/${cfg.directory}";

  pin = pkgs.writeShellApplication {
    name = "pin-last-good-boot";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      booted=$(readlink -f /run/booted-system)
      if [ ! -e "$booted/kernel" ] || [ ! -e "$booted/initrd" ]; then
        echo "booted system has no kernel to pin" >&2
        exit 0
      fi
      if [ "$(readlink -f ${gcRoot} 2>/dev/null || true)" = "$booted" ]; then
        exit 0
      fi
      if ! mountpoint -q ${bootMount}; then
        echo "${bootMount} is not mounted" >&2
        exit 1
      fi

      ln -sfn "$booted" ${gcRoot}

      mkdir -p ${payloadDir}
      cp -f "$(readlink -f "$booted/kernel")" ${payloadDir}/kernel.tmp
      cp -f "$(readlink -f "$booted/initrd")" ${payloadDir}/initrd.tmp
      mv -f ${payloadDir}/kernel.tmp ${payloadDir}/kernel
      mv -f ${payloadDir}/initrd.tmp ${payloadDir}/initrd

      params=$(cat "$booted/kernel-params")
      {
        echo 'menuentry "${cfg.title}" --class nixos --unrestricted {'
        echo '  search --set=drive1 --fs-uuid ${bootUuid}'
        echo "  linux (\$drive1)/${cfg.directory}/kernel init=$booted/init $params"
        echo "  initrd (\$drive1)/${cfg.directory}/initrd"
        echo '}'
      } > ${menuFile}.tmp
      mv -f ${menuFile}.tmp ${menuFile}
    '';
  };
in

{
  options.local.lastGoodBoot = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.boot.loader.grub.enable && config.boot.loader.grub.efiSupport;
      description = "Keep the last successfully booted generation as its own GRUB entry.";
    };

    title = lib.mkOption {
      type = lib.types.str;
      default = "Previous successful boot";
      description = "Menu entry label.";
    };

    directory = lib.mkOption {
      type = lib.types.strMatching "[a-z0-9-]+";
      default = "previous-successful-boot";
      description = "Name of the payload directory and menu fragment on the ESP.";
    };

    settleMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Uptime after which the current boot counts as successful.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/dev/disk/by-uuid/" bootDevice;
        message = "local.lastGoodBoot needs ${bootMount} declared by UUID, got ${bootDevice}.";
      }
    ];

    boot.loader.grub.extraEntries = ''
      search --set=lastgood --fs-uuid ${bootUuid}
      if [ -f ($lastgood)/grub/${cfg.directory}.cfg ]; then
        source ($lastgood)/grub/${cfg.directory}.cfg
      fi
    '';

    systemd.services.pin-last-good-boot = {
      description = "Pin the last successfully booted generation";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe pin;
      };
    };

    systemd.timers.pin-last-good-boot = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.settleMinutes}m";
        AccuracySec = "1m";
      };
    };
  };
}

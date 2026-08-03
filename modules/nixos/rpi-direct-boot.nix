# Boot a Raspberry Pi from the GPU firmware, no U-Boot. Pi 5 U-Boot has no
# USB/PCIe driver, so it cannot reach a kernel on a USB root.

{
  config,
  options,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.rpi.directBoot;

  configTxt = pkgs.buildPackages.runCommand "config.txt" { } ''
    cat ${options.hardware.raspberry-pi.configtxt.file.default} > $out
    printf 'initramfs initrd followkernel\n' >> $out
  '';

  mkStage =
    scriptPkgs:
    scriptPkgs.writeShellApplication {
      name = "stage-rpi-boot";
      runtimeInputs = [ scriptPkgs.coreutils ];
      text = ''
        target="$1"
        toplevel="$2"
        boot=${cfg.firmwarePackage}/share/raspberrypi/boot

        install -d "$target/overlays"

        replace() {
          cp "$1" "$2.tmp"
          mv "$2.tmp" "$2"
        }

        for dtb in "$boot"/bcm2712-*.dtb; do
          replace "$dtb" "$target/$(basename "$dtb")"
        done
        for ovr in "$boot"/overlays/*; do
          replace "$ovr" "$target/overlays/$(basename "$ovr")"
        done
        for f in "$boot"/bootcode.bin "$boot"/start*.elf "$boot"/fixup*.dat; do
          [ -e "$f" ] || continue
          replace "$f" "$target/$(basename "$f")"
        done

        replace ${configTxt} "$target/config.txt"

        for f in Image initrd; do
          if [ -e "$target/$f" ]; then
            replace "$target/$f" "$target/$f.prev"
          fi
        done

        replace "$toplevel/kernel" "$target/Image"
        replace "$toplevel/initrd" "$target/initrd"

        printf '%s init=%s\n' "$(cat "$toplevel/kernel-params")" "$toplevel/init" \
          > "$target/cmdline.txt.tmp"
        mv "$target/cmdline.txt.tmp" "$target/cmdline.txt"
      '';
    };

  stage = mkStage pkgs;
in

{
  options.local.rpi.directBoot = {
    enable = lib.mkEnableOption "booting the kernel straight from the Pi GPU firmware";

    firmwarePath = lib.mkOption {
      type = lib.types.str;
      default = "/boot/firmware";
      description = "Mount point of the Pi firmware (FAT) partition.";
    };

    firmwarePackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.raspberrypifw;
      defaultText = lib.literalExpression "pkgs.raspberrypifw";
    };

    stagePackage = lib.mkOption {
      type = lib.types.package;
      default = mkStage pkgs.buildPackages;
      readOnly = true;
      description = "stage-rpi-boot <firmware-dir> <toplevel>, for image builders.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        hardware.raspberry-pi.firmware.enable = false;
        hardware.raspberry-pi.configtxt.settings.all.kernel = "Image";
        hardware.raspberry-pi.configtxt.file = lib.mkForce configTxt;

        boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;

        boot.loader.external = {
          enable = true;
          installHook = pkgs.writeShellScript "install-rpi-boot" ''
            ${lib.getExe stage} ${lib.escapeShellArg cfg.firmwarePath} "$1"
          '';
        };

        assertions = [
          {
            assertion = !config.boot.loader.grub.enable;
            message = "local.rpi.directBoot and GRUB are both enabled.";
          }
        ];
      }

      (lib.optionalAttrs (options ? sdImage) {
        # nixos-hardware mkForces this for U-Boot, regardless of firmware.enable.
        sdImage.populateFirmwareCommands = lib.mkOverride 10 ''
          ${lib.getExe cfg.stagePackage} ./firmware ${config.system.build.toplevel}
        '';

        sdImage.populateRootCommands = ''
          mkdir -p ./files/boot
        '';
      })
    ]
  );
}

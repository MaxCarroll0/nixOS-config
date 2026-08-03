{
  lib,
  inputs,
  ...
}:

{
  imports = [
    inputs.nixos-hardware.nixosModules.raspberry-pi-5
    ../../modules/nixos/rpi-direct-boot.nix
  ];

  local.rpi.directBoot.enable = true;

  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  # ASM1153 UAS resets and corrupts under load on the Pi.
  boot.kernelParams = [ "usb-storage.quirks=174c:55aa:u" ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "usb-storage"
    "uas"
  ];

  services.fstrim.enable = true;
}

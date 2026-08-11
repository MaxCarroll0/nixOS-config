{
  lib,
  nixos-raspberrypi,
  ...
}:

{
  imports = with nixos-raspberrypi.nixosModules; [
    raspberry-pi-5.base
    trusted-nix-caches
  ];

  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  boot.loader.raspberry-pi.bootloader = "kernel";

  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [
      "x-initrd.mount"
      "noatime"
    ];
  };

  fileSystems."/boot/firmware" = lib.mkDefault {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [
      "noatime"
      "noauto"
      "x-systemd.automount"
      "x-systemd.idle-timeout=1min"
    ];
  };

  hardware.raspberry-pi.config.all = {
    base-dt-params.pciex1.enable = true;
    dt-overlays.pcie-32bit-dma-pi5.enable = true;
    options.usb_max_current_enable = {
      enable = true;
      value = true;
    };
  };

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "usb-storage"
    "uas"
  ];

  services.fstrim.enable = true;
}

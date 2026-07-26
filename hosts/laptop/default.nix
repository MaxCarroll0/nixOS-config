# ThinkPad: workstation only, offloads builds to the desktop.

{ ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-env.nix
    ../../modules/nixos/vpn.nix
    ../../modules/nixos/build-client.nix
  ];

  networking.hostName = "laptop";

  sops.age.keyFile = "/home/max/.config/sops/age/keys.txt";

  boot.loader.grub.extraEntries = ''
    menuentry "Ubuntu iso" {
      insmod ext2
      set isofile="/ubuntu/ubuntu.iso"
      loopback loop (hd0,5)$isofile
      linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=$isofile quiet noeject noprompt splash
      initrd (loop)/casper/initrd
    }
  '';

  local.build.client = {
    enable = true;
    builderHost = "desktop";
    maxJobs = 8;
    speedFactor = 4;
  };
}

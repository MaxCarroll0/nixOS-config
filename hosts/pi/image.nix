# Bootable image for the Pi's USB SSD. Not part of the installed system.

{ modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/sd-card/sd-image.nix") ];

  sdImage.compressImage = false;

  # sd-image.nix writes 0x0b; the Pi bootloader wants 0x0c (FAT32 LBA).
  sdImage.postBuildCommands = "sfdisk --part-type $img 1 c";

  sdImage.firmwareSize = 1024;

  networking.firewall.allowedTCPPorts = [ 2222 ];
  local.server.ssh.allowGlobalTCPPorts = [ 2222 ];
}

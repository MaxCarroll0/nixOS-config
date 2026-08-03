# Bootable image for the Pi's USB SSD. Not part of the installed system.

{ modulesPath, ... }:

{
  # sd-image.nix, not sd-image-aarch64.nix: the latter hardcodes U-Boot and
  # extlinux, and filterOverrides forces those definitions even when overridden.
  imports = [ (modulesPath + "/installer/sd-card/sd-image.nix") ];

  sdImage.compressImage = false;

  # Direct boot keeps the kernel, initrd and one previous pair of each here,
  # alongside the vendor firmware; the 30M default is for extlinux, which
  # keeps them on the root partition instead.
  sdImage.firmwareSize = 1024;

  # Image only: switching to hosts/pi closes this again.
  networking.firewall.allowedTCPPorts = [ 2222 ];
  local.server.ssh.allowGlobalTCPPorts = [ 2222 ];
}

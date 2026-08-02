{
  config,
  lib,
  pkgs,
  modulesPath,
  inputs,
  ...
}:

{
  imports = [
    inputs.nixos-hardware.nixosModules.raspberry-pi-5
    (modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.loader.generic-extlinux-compatible.configurationLimit = 5;
}

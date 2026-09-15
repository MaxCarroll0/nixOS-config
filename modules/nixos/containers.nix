# Rootless podman and distrobox, for running foreign-distro binaries.

{
  config,
  lib,
  pkgs,
  ...
}:

{
  options.local.containers.enable = lib.mkEnableOption "rootless podman and distrobox";

  config = lib.mkIf config.local.containers.enable {
    virtualisation.podman = {
      enable = true;
      autoPrune = {
        enable = true;
        dates = "weekly";
      };
    };

    environment.systemPackages = [ pkgs.distrobox ];
  };
}

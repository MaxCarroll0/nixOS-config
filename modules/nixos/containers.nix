# Rootless podman and distrobox, for running foreign-distro binaries.

{ pkgs, ... }:

{
  virtualisation.podman = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  environment.systemPackages = [ pkgs.distrobox ];
}

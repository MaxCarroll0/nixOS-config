{ lib, pkgs, ... }:

{
  home.packages = with pkgs; [ ];

  programs.kitty.enable = true;

  wayland.windowManager.hyprland = {
    enable = true; # enable Hyprland

    settings = {

    };
  };

  # KDE uses the NixOS portal set. Letting Home Manager generate its own
  # Hyprland-only portal directory hides xdg-desktop-portal-kde from KDE.
  xdg.portal.enable = lib.mkForce false;
}

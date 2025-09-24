{ config, pkgs, ... }:

{
  home.packages = with pkgs; [

  ];


  programs.kitty.enable = true;

  wayland.windowManager.hyprland = {
    enable = true; # enable Hyprland

    settings = {

    };
  };
}

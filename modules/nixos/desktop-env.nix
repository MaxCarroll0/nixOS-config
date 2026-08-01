# Graphical session: Plasma, Hyprland, audio, printing, Firefox.

{
  pkgs,
  pkgs-unstable,
  inputs,
  ...
}:

{
  services.printing.enable = true;

  services.logind.settings.Login.HandleLidSwitch = "ignore";

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;

  services.xserver.xkb.layout = "gb";
  hardware.keyboard.qmk.enable = true;

  programs.firefox = {
    enable = true;
    package = pkgs-unstable.firefox;
    preferencesStatus = "user";
    preferences = {
      "media.navigator.enabled" = true;
      "media.peerconnection.enabled" = true;
      "media.getusermedia.screensharing.enabled" = true;
      "media.webrtc.capture.allow-pipewire" = true;
      "privacy.resistFingerprinting" = false;
      "privacy.resistFingerprinting.pbmode" = false;
      "privacy.resistFingerprinting.randomization.canvas.use_siphash" = false;
      "privacy.resistFingerprinting.randomization.daily_reset.enabled" = false;
      "privacy.resistFingerprinting.randomization.daily_reset.private.enabled" = false;
    };
  };

  programs.hyprland.enable = true;
  programs.hyprland.withUWSM = true;
  programs.hyprland.package = inputs.hyprland.packages."${pkgs.stdenv.hostPlatform.system}".hyprland;
}

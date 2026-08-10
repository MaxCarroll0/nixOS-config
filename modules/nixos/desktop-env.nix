# Graphical session: Plasma, Hyprland, audio, printing, Firefox.

{
  lib,
  pkgs,
  pkgs-unstable,
  inputs,
  ...
}:

let
  # KDE askpass keeps sudo passwords out of the invoking terminal.
  sudoRequest = pkgs.writeShellApplication {
    name = "sudo-request";
    runtimeInputs = [
      pkgs.kdePackages.ksshaskpass
      pkgs.tailscale
    ];
    text = ''
      if [ "''${1:-}" = "--host" ]; then
        if [ "$#" -lt 3 ]; then
          echo "usage: sudo-request --host HOST COMMAND [ARG ...]" >&2
          exit 2
        fi
        host="$2"
        shift 2
        printf -v command '%q ' "$@"
        password="$(${lib.getExe pkgs.kdePackages.ksshaskpass} "Authorize sudo on $host: $command")" || exit
        [ -n "$password" ] || exit 1
        printf '%s\n' "$password" \
          | tailscale ssh "$host" "/run/wrappers/bin/sudo -k; /run/wrappers/bin/sudo -S -p \"\" -- $command; status=\$?; /run/wrappers/bin/sudo -k; exit \$status"
        status=$?
        unset password
      else
        nestedHost=""
        args=("$@")
        for i in "''${!args[@]}"; do
          if [ "''${args[$i]}" = "--host" ] && [ $((i + 1)) -lt "''${#args[@]}" ]; then
            nestedHost="''${args[$((i + 1))]}"
            break
          fi
        done

        if [ -n "$nestedHost" ]; then
          printf -v command '%q ' "$@"
          password="$(${lib.getExe pkgs.kdePackages.ksshaskpass} "Authorize sudo on $nestedHost: $command")" || exit
          [ -n "$password" ] || exit 1
          status=0
          { while :; do printf '%s\n' "$password"; done; } | "$@" || status=$?
          unset password
        else
          /run/wrappers/bin/sudo -k
          SUDO_ASKPASS=${lib.getExe pkgs.kdePackages.ksshaskpass} /run/wrappers/bin/sudo --askpass --validate || exit
          status=0
          "$@" || status=$?
          /run/wrappers/bin/sudo -k
        fi
      fi
      exit "$status"
    '';
  };
in

{
  programs.firejail.enable = true;

  users.users.max.packages = [ pkgs.kdePackages.kate ];

  environment.systemPackages = [
    sudoRequest
  ]
  ++ (with pkgs; [
    vscode
    wayland-utils
    wl-clipboard
  ]);

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

# Graphical session: Plasma, Hyprland, audio, printing, Firefox.

{
  lib,
  pkgs,
  pkgs-unstable,
  inputs,
  ...
}:

let
  askpass = lib.getExe pkgs.kdePackages.ksshaskpass;
  sshAdd = lib.getExe' pkgs.openssh "ssh-add";
  sshAgent = lib.getExe' pkgs.openssh "ssh-agent";

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
        password="$(${askpass} "Authorize sudo on $host: $command")" || exit
        [ -n "$password" ] || exit 1
        printf '%s\n' "$password" \
          | tailscale ssh "$host" "/run/wrappers/bin/sudo -k; /run/wrappers/bin/sudo -S -p \"\" -- $command; status=\$?; /run/wrappers/bin/sudo -k; exit \$status"
        status=$?
        unset password
      else
        if [ "$#" -eq 0 ]; then
          echo "usage: sudo-request COMMAND [ARG ...]" >&2
          exit 2
        fi
        /run/wrappers/bin/sudo -k
        status=0
        SUDO_ASKPASS=${askpass} /run/wrappers/bin/sudo --askpass -- "$@" || status=$?
        /run/wrappers/bin/sudo -k
      fi
      exit "$status"
    '';
  };

  deployRequest = pkgs.writeShellApplication {
    name = "deploy-request";
    excludeShellChecks = [ "SC2016" ];
    text = ''
      if [ "''${1:-}" != "--host" ] || [ "$#" -lt 2 ]; then
        echo "usage: deploy-request --host HOST [ACTION] [ARG ...]" >&2
        exit 2
      fi

      export SSH_ASKPASS=${askpass}
      export SSH_ASKPASS_REQUIRE=force
      export DISPLAY="''${DISPLAY:-:0}"
      export REBUILD_SSH_AGENT_SUDO=1

      exec ${sshAgent} ${pkgs.bash}/bin/bash -ec '
        ${sshAdd} "$HOME/.ssh/id_ed25519"
        exec rebuild "$@"
      ' deploy-request "$@"
    '';
  };

  sudoGrant = pkgs.writeShellApplication {
    name = "sudo-grant";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      agentSocket="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sudo-agent"

      case "''${1:-8h}" in
        status)
          SSH_AUTH_SOCK="$agentSocket" ${sshAdd} -l
          exit ;;
        revoke)
          SSH_AUTH_SOCK="$agentSocket" ${sshAdd} -D
          exit ;;
      esac

      if [ "$#" -gt 1 ]; then
        echo "usage: sudo-grant [DURATION|status|revoke]" >&2
        exit 2
      fi

      duration="''${1:-8h}"
      systemctl --user start sudo-agent.service
      for _ in $(seq 1 50); do
        [ -S "$agentSocket" ] && break
        sleep 0.1
      done
      if [ ! -S "$agentSocket" ]; then
        echo "sudo SSH agent did not start" >&2
        exit 1
      fi

      SSH_AUTH_SOCK="$agentSocket" ${sshAdd} -D >/dev/null
      SSH_AUTH_SOCK="$agentSocket" \
        SSH_ASKPASS=${askpass} \
        SSH_ASKPASS_REQUIRE=force \
        DISPLAY="''${DISPLAY:-:0}" \
        ${sshAdd} -t "$duration" "$HOME/.ssh/id_ed25519"
      echo "sudo grant active for $duration"
    '';
  };

  sudoGranted = pkgs.writeShellApplication {
    name = "sudo-granted";
    text = ''
      if [ "$#" -eq 0 ]; then
        echo "usage: sudo-granted COMMAND [ARG ...]" >&2
        exit 2
      fi

      export SSH_AUTH_SOCK="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sudo-agent"
      if ! ${sshAdd} -l >/dev/null 2>&1; then
        echo "no active sudo grant; run: sudo-grant 8h" >&2
        exit 1
      fi
      export REBUILD_SSH_AGENT_SUDO=1
      exec "$@"
    '';
  };
in

{
  programs.firejail.enable = true;

  users.users.max.packages = [ pkgs.kdePackages.kate ];

  environment.systemPackages = [
    deployRequest
    sudoGrant
    sudoGranted
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
  services.displayManager.autoLogin = {
    enable = true;
    user = "max";
  };

  services.xserver.xkb.layout = "gb";
  services.xserver.xkb.options = "caps:escape";
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

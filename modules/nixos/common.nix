# Settings shared by every host: nix, secrets, locale, users, upgrades.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  flakePath = "/home/max/.config/nix";
  cfg = config.local.users;

  rebuild = pkgs.writeShellApplication {
    name = "rebuild";
    runtimeInputs = [ pkgs.git ];
    text = ''
      host="${config.networking.hostName}"
      flake="${flakePath}"
      opts=()

      if [ "''${1:-}" = "--local" ]; then
        opts+=(--option builders "")
        shift
      fi

      action="''${1:-switch}"
      [ $# -gt 0 ] && shift

      untracked=$(git -C "$flake" ls-files --others --exclude-standard -- '*.nix' 'secrets/*' || true)
      if [ -n "$untracked" ]; then
        mapfile -t untrackedFiles <<< "$untracked"
        echo "warning: untracked files, invisible to the flake:" >&2
        printf '  %s\n' "''${untrackedFiles[@]}" >&2
      fi

      case "$action" in
        home)
          exec home-manager switch --flake "$flake#max@$host" "''${opts[@]}" "$@" ;;
        build|dry-build|repl)
          exec nixos-rebuild "$action" --flake "$flake#$host" "''${opts[@]}" "$@" ;;
        switch|boot|test|dry-activate)
          nixos-rebuild build --flake "$flake#$host" "''${opts[@]}" "$@"
          exec sudo nixos-rebuild "$action" --flake "$flake#$host" "''${opts[@]}" "$@" ;;
        *)
          exec sudo nixos-rebuild "$action" --flake "$flake#$host" "''${opts[@]}" "$@" ;;
      esac
    '';
  };

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
        /run/wrappers/bin/sudo -k
        SUDO_ASKPASS=${lib.getExe pkgs.kdePackages.ksshaskpass} /run/wrappers/bin/sudo --askpass --validate || exit
        status=0
        "$@" || status=$?
        /run/wrappers/bin/sudo -k
      fi
      exit "$status"
    '';
  };

  editSecrets = pkgs.writeShellApplication {
    name = "edit-secrets";
    text = ''
      ageKey=$(sudo ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key)
      export SOPS_AGE_KEY="$ageKey"
      exec ${pkgs.sops}/bin/sops ${flakePath}/secrets/secrets.yaml
    '';
  };

  projectClosureRetention = pkgs.writeShellApplication {
    name = "project-closure-retention";
    runtimeInputs = [
      config.nix.package
      pkgs.angrr
      pkgs.python3
    ];
    text = ''
      exec python3 ${./project-closure-retention.py} "$@"
    '';
  };

in

{
  options.local.users.sopsPasswords = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example = {
      alice = "alice-password-hash";
    };
    description = "Accounts whose password hash comes from sops.";
  };

  config = {
    boot.loader.grub.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.loader.efi.efiSysMountPoint = "/boot";
    boot.loader.grub.efiSupport = true;
    boot.loader.grub.device = "nodev";
    boot.loader.grub.configurationLimit = 20;

    boot.kernelParams = [
      "zswap.enabled=1"
      "zswap.compressor=zstd"
      "zswap.zpool=z3fold"
      "zswap.max_pool_percent=20"
    ];

    swapDevices = [
      {
        device = "/swapfile";
        size = 8 * 1024;
      }
    ];

    services.earlyoom = {
      enable = true;
      freeMemThreshold = lib.mkDefault 5;
      freeSwapThreshold = lib.mkDefault 10;
    };

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    nix.settings.connect-timeout = 5;
    nix.settings.fallback = true;
    nix.settings.builders-use-substitutes = true;
    nix.settings.substituters = [
      "https://hyprland.cachix.org"
      "https://nix-community.cachix.org"
    ];
    nix.settings.trusted-substituters = [
      "https://hyprland.cachix.org"
      "https://nix-community.cachix.org"
    ];
    nix.settings.trusted-public-keys = [
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
    nix.settings.trusted-users = [
      "root"
      "@wheel"
    ];

    nix.optimise.automatic = true;
    nix.optimise.dates = [ "*-*-2,16 04:15:00" ];

    programs.nh = {
      enable = true;
      flake = flakePath;
      clean = {
        enable = true;
        dates = "daily";
        extraArgs = "--keep 10 --keep-since 14d --no-gcroots";
      };
    };

    systemd.services.nh-clean.preStart = /* bash */ ''
      ${projectClosureRetention}/bin/project-closure-retention --apply
    '';

    local.users.sopsPasswords.max = "max-password-hash";
    users.mutableUsers = false;

    # Declared here whoever consumes them: Home Manager runs as the user and
    # cannot read a root-only host key.
    sops = {
      defaultSopsFile = ../../secrets/secrets.yaml;
      defaultSopsFormat = "yaml";

      secrets = {
        github-API = { };
        exercism-API.owner = "max";
      }
      # Decrypted to /run/secrets-for-users before accounts exist, so these
      # cannot take an owner.
      // lib.mapAttrs' (_: secret: lib.nameValuePair secret { neededForUsers = true; }) cfg.sopsPasswords;

      templates."conf-access-tokens" = {
        content = "extra-access-tokens = github.com=${config.sops.placeholder.github-API}";
        owner = "max";
      };
    };

    # !include, not readFile: readFile which needs--impure
    nix.extraOptions = "!include ${config.sops.templates."conf-access-tokens".path}";

    # nixos-rebuild's --update-input was removed; inputs are bumped separately.
    # The unit runs as root, so hand the lock back to its owner afterwards.
    systemd.services.nixos-upgrade.preStart = /* bash */ ''
      ${pkgs.git}/bin/git config --global --add safe.directory ${flakePath}
      ${config.nix.package}/bin/nix flake update --flake ${flakePath} nixpkgs nixpkgs-unstable
      ${pkgs.coreutils}/bin/chown max:users ${flakePath}/flake.lock
    '';

    system.autoUpgrade = {
      enable = true;
      allowReboot = true;
      flake = "${flakePath}#${config.networking.hostName}";
      flags = [ "-L" ];
      dates = "weekly";
      randomizedDelaySec = "45min";
      rebootWindow = {
        lower = "03:00";
        upper = "05:00";
      };
    };

    networking.networkmanager.enable = true;

    programs.firejail.enable = true;

    time.timeZone = "Europe/London";

    i18n.defaultLocale = "en_GB.UTF-8";

    i18n.extraLocaleSettings = {
      LC_ADDRESS = "en_GB.UTF-8";
      LC_IDENTIFICATION = "en_GB.UTF-8";
      LC_MEASUREMENT = "en_GB.UTF-8";
      LC_MONETARY = "en_GB.UTF-8";
      LC_NAME = "en_GB.UTF-8";
      LC_NUMERIC = "en_GB.UTF-8";
      LC_PAPER = "en_GB.UTF-8";
      LC_TELEPHONE = "en_GB.UTF-8";
      LC_TIME = "en_GB.UTF-8";
    };

    console.keyMap = "uk";

    users.users = lib.mkMerge [
      (lib.mapAttrs (_: secret: {
        hashedPasswordFile = config.sops.secrets.${secret}.path;
      }) cfg.sopsPasswords)
      {
        max = {
          isNormalUser = true;
          description = "Max Carroll";
          extraGroups = [
            "networkmanager"
            "wheel"
            "keys"
            "novpn"
          ];
          packages = with pkgs; [
            kdePackages.kate
          ];
        };
      }
    ];

    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = [
      rebuild
      editSecrets
      projectClosureRetention
      sudoRequest
      pkgs.nix-sweep
    ]
    ++ (with pkgs; [
      git
      vscode
      wayland-utils
      wl-clipboard
    ]);

    system.stateVersion = lib.mkDefault "25.05";

    warnings = lib.mapAttrsToList (
      name: _:
      "${name} has a sops password but users.mutableUsers is true, so it only applies at account creation."
    ) (lib.optionalAttrs config.users.mutableUsers cfg.sopsPasswords);
  };
}

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
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
      pkgs.getent
      pkgs.util-linux
    ];
    text = ''
      host="${config.networking.hostName}"
      flake="${flakePath}"
      opts=()
      rebuildStarted=$SECONDS
      rebuildKind=rebuild
      rebuildTarget="$host"
      rebuildAction=switch

      logRebuildCompletion() {
        rebuildExit=$?
        trap - EXIT
        if [ "$rebuildExit" -eq 0 ]; then
          rebuildStatus=success
        else
          rebuildStatus=failed
        fi
        logger -t nix-observer-summary -- "{\"event\":\"nix_rebuild\",\"status\":\"$rebuildStatus\",\"exit_code\":$rebuildExit,\"duration_seconds\":$((SECONDS - rebuildStarted)),\"host\":\"$host\",\"project\":\"nix\",\"kind\":\"$rebuildKind\",\"target\":\"$rebuildTarget\",\"action\":\"$rebuildAction\",\"alert_eligible\":true}"
        exit "$rebuildExit"
      }
      trap logRebuildCompletion EXIT

      target=""
      profile=""
      while true; do
        case "''${1:-}" in
          --local)
            opts+=(--option builders "")
            shift ;;
          --host)
            target="''${2:?--host needs a node name}"
            shift 2 ;;
          --profile)
            profile="''${2:?--profile needs system or home}"
            shift 2 ;;
          *) break ;;
        esac
      done

      action="''${1:-switch}"
      [ $# -gt 0 ] && shift

      export NIX_OBSERVER_KIND=rebuild
      export NIX_OBSERVER_TARGET="''${target:-$host}"
      rebuildTarget="$NIX_OBSERVER_TARGET"
      rebuildAction="$action"

      untracked=$(git -C "$flake" ls-files --others --exclude-standard -- '*.nix' 'secrets/*' || true)
      if [ -n "$untracked" ]; then
        mapfile -t untrackedFiles <<< "$untracked"
        echo "warning: untracked files, invisible to the flake:" >&2
        printf '  %s\n' "''${untrackedFiles[@]}" >&2
      fi

      if [ -n "$target" ]; then
        deployOpts=()
        case "$action" in
          switch) ;;
          boot) deployOpts+=(--boot) ;;
          test) deployOpts+=(--test) ;;
          dry-activate) deployOpts+=(--dry-activate) ;;
          home)
            echo "error: --host deploys the home profile alongside the system" >&2
            exit 2 ;;
          *)
            echo "error: $action is not a deploy action" >&2
            exit 2 ;;
        esac

        export NIX_CONFIG="accept-flake-config = true"

        deployTarget="$flake#$target"
        [ -n "$profile" ] && deployTarget="$flake#$target.$profile"

        printf -v deployCmd '%q ' nix run "$flake#deploy-rs" -- \
          --skip-checks "$deployTarget" "''${deployOpts[@]}" "$@"

        if getent group novpn >/dev/null 2>&1; then
          /run/wrappers/bin/sg novpn -c "$deployCmd"
          exit $?
        fi
        ${pkgs.bash}/bin/bash -c "$deployCmd"
        exit $?
      fi

      case "$action" in
        switch|boot)
          if [ -n "''${SSH_CONNECTION:-}" ]; then
            echo "error: remote session; activating here has no rollback guarantee" >&2
            echo "  from your workstation: rebuild --host $host $action" >&2
            exit 1
          fi ;;
      esac

      case "$action" in
        home)
          export NIX_OBSERVER_KIND=home-rebuild
          rebuildKind=home-rebuild
          home-manager switch --flake "$flake#max@$host" "''${opts[@]}" "$@" ;;
        build|dry-build|repl)
          nixos-rebuild "$action" --flake "$flake#$host" "''${opts[@]}" "$@" ;;
        switch|boot|test|dry-activate)
          nixos-rebuild build --flake "$flake#$host" "''${opts[@]}" "$@"
          sudo nixos-rebuild "$action" --flake "$flake#$host" "''${opts[@]}" "$@" ;;
        *)
          sudo nixos-rebuild "$action" --flake "$flake#$host" "''${opts[@]}" "$@" ;;
      esac
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
  imports = [ ./nix-observer.nix ];

  options.local.users.sopsPasswords = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example = {
      alice = "alice-password-hash";
    };
    description = "Accounts whose password hash comes from sops.";
  };

  config = {
    boot.loader.grub.enable = lib.mkDefault true;
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
    boot.loader.efi.efiSysMountPoint = lib.mkDefault "/boot";
    boot.loader.grub.efiSupport = lib.mkDefault true;
    boot.loader.grub.device = lib.mkDefault "nodev";
    boot.loader.grub.configurationLimit = lib.mkDefault 20;

    boot.kernelParams = [
      "zswap.enabled=1"
      "zswap.compressor=zstd"
      "zswap.zpool=zsmalloc"
      "zswap.max_pool_percent=20"
    ];

    swapDevices = [
      {
        device = "/swapfile";
        size = 8 * 1024;
        randomEncryption.enable = true;
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

    local.monitoring.nixBuilds.enable = true;

    services.journald.extraConfig = ''
      Storage=persistent
    '';

    nix.settings.connect-timeout = 5;
    # rebuild evaluates the flake again under sudo, and git refuses a repo owned
    # by another user.
    environment.etc."gitconfig".text = ''
      [safe]
        directory = ${flakePath}
    '';

    nix.settings.fallback = true;
    nix.settings.builders-use-substitutes = true;
    nix.settings.substituters = [
      "https://hyprland.cachix.org"
      "https://nix-community.cachix.org"
      "https://nixos-raspberrypi.cachix.org"
    ];
    nix.settings.trusted-substituters = [
      "https://hyprland.cachix.org"
      "https://nix-community.cachix.org"
      "https://nixos-raspberrypi.cachix.org"
    ];
    nix.settings.trusted-public-keys = [
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
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
        extraArgs = "--keep 10 --keep-since 14d";
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
      if [ -d ${flakePath}/.git ]; then
        ${pkgs.git}/bin/git config --global --add safe.directory ${flakePath}
        ${config.nix.package}/bin/nix flake update --flake ${flakePath} nixpkgs nixpkgs-unstable
        ${pkgs.coreutils}/bin/chown max:users ${flakePath}/flake.lock
      fi
    '';

    system.autoUpgrade = {
      enable = lib.mkDefault false;
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

    networking.networkmanager.wifi.powersave = false;

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
          ];
        };
      }
    ];

    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = [
      rebuild
      editSecrets
      projectClosureRetention
      pkgs.nix-sweep
      pkgs.git
    ];

    system.stateVersion = lib.mkDefault "25.05";

    warnings = lib.mapAttrsToList (
      name: _:
      "${name} has a sops password but users.mutableUsers is true, so it only applies at account creation."
    ) (lib.optionalAttrs config.users.mutableUsers cfg.sopsPasswords);
  };
}

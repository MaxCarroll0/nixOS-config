# Settings shared by every host: nix, secrets, locale, users, upgrades.

{
  config,
  pkgs,
  lib,
  facts,
  ...
}:

let
  flakePath = "/home/max/.config/nix";
  cfg = config.local.users;

  selfName = config.networking.hostName;

  onTailnet = lib.filterAttrs (_: f: f ? tailscale) facts;
  tailnetNames = lib.mapAttrs (_: f: f.tailscale or f.tailnetAddress) (
    lib.filterAttrs (_: f: f ? tailscale || f ? tailnetAddress) facts
  );
  wakeable = lib.filterAttrs (name: f: name != selfName && f ? mac) facts;

  editSecrets = pkgs.writeShellApplication {
    name = "edit-secrets";
    text = ''
      ageKey=$(sudo ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key)
      export SOPS_AGE_KEY="$ageKey"
      exec ${pkgs.sops}/bin/sops ${flakePath}/secrets/secrets.yaml
    '';
  };

  # Every recipe addresses the flake with relative paths, so running one from
  # elsewhere needs both the justfile and the working directory pointed at the clone.
  nixConfig = pkgs.writeShellApplication {
    name = "nix-config";
    runtimeInputs = [ pkgs.just ];
    text = ''
      exec just --justfile ${flakePath}/justfile --working-directory ${flakePath} "$@"
    '';
  };

in

{
  imports = [
    ./deploy.nix
    ./dev-build.nix
    ./flake-sync.nix
    ./upgrade.nix
    ./peer-transport.nix
    ./nix-observer.nix
    ./unclean-boot.nix
    ./last-good-boot.nix
    ./disk.nix
  ];

  options.local.users.sopsPasswords = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example = {
      alice = "alice-password-hash";
    };
    description = "Accounts whose password hash comes from sops.";
  };

  config = {
    # Proton owns resolv.conf and Tailscale DNS is deliberately disabled, while
    # Tailscale Serve still requires the node's MagicDNS host name.
    networking.hosts = lib.mapAttrs' (
      name: address:
      lib.nameValuePair address [
        name
        "${name}.taild5b88a.ts.net"
      ]
    ) tailnetNames;

    local.peerTransport = {
      enable = true;
      peers = lib.mapAttrs (_: f: { tailscaleAddress = f.tailscale; }) onTailnet;
    };

    local.wake = {
      peers = lib.mapAttrs (_: f: { mac = lib.mkDefault f.mac; }) wakeable;
      relays = lib.mapAttrs (_: f: f.tailscale) (lib.filterAttrs (name: _: name != selfName) onTailnet);
    };
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

    # randomEncryption gives the swapfile a new UUID every boot, so a hibernation
    # image is unresumable and its stale HibernateLocation EFI variable costs the
    # next boot a two-minute device timeout.
    systemd.sleep.settings.Sleep = {
      AllowHibernation = false;
      AllowHybridSleep = false;
      AllowSuspendThenHibernate = false;
    };

    systemd.services.systemd-suspend.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS = "false";

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
      SystemMaxUse=1G
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
    };

    local.users.sopsPasswords.max = "max-password-hash";
    users.mutableUsers = false;

    # Declared here whoever consumes them: Home Manager runs as the user and
    # cannot read a root-only host key.
    sops = {
      defaultSopsFile = ../../secrets/secrets.yaml;
      defaultSopsFormat = "yaml";

      secrets = {
        github-API.owner = "max";
        exercism-API.owner = "max";
        claude-swap-export = {
          sopsFile = ../../secrets/claude-swap.json;
          format = "json";
          owner = "max";
          mode = "0400";
        };
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

    security.pki.certificates = [ (builtins.readFile ../../keys/home-ca.crt) ];

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
      editSecrets
      nixConfig
      config.local.disk.retention
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

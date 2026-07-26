# Settings shared by every host: nix, secrets, locale, users, upgrades.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  flakePath = "/home/max/.config/nix";
in

{
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
    freeMemThreshold = 5;
    freeSwapThreshold = 10;
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.optimise.automatic = true;
  nix.optimise.dates = [ "*-*-2,16 04:15:00" ];

  programs.nh = {
    enable = true;
    flake = flakePath;
    clean = {
      enable = true;
      dates = "*-*-1,15 03:15:00";
      extraArgs = "--keep 10 --keep-since 14d";
    };
  };

  sops = {
    defaultSopsFile = ../../secrets/secrets.yaml;
    defaultSopsFormat = "yaml";

    secrets = {
      github-API = { };
    };

    templates."conf-access-tokens" = {
      content = "extra-access-tokens = github.com=${config.sops.placeholder.github-API}";
      owner = "max";
    };
  };

  nix.extraOptions = "!include ${config.sops.templates."conf-access-tokens".path}";

  # nixos-rebuild's --update-input was removed; inputs are bumped separately.
  # The unit runs as root, so hand the lock back to its owner afterwards.
  systemd.services.nixos-upgrade.preStart = ''
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

  users.users.max = {
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

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    git
    vscode
    wayland-utils
    wl-clipboard
  ];

  system.stateVersion = lib.mkDefault "25.05";
}

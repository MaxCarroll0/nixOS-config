# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{
  config,
  pkgs,
  pkgs-unstable,
  inputs,
  ...
}:

{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
  ];

  # Bootloader.
  boot.loader.grub.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot";
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.device = "nodev";
  boot.loader.grub.configurationLimit = 10;
  boot.loader.grub.extraEntries = ''
    menuentry "Ubuntu iso" {
      insmod ext2
      set isofile="/ubuntu/ubuntu.iso"
      loopback loop (hd0,5)$isofile
      linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=$isofile quiet noeject noprompt splash
      initrd (loop)/casper/initrd
    }
  '';

  boot.kernelParams = [
    "zswap.enabled=1"
    "zswap.compressor=zstd"
    "zswap.zpool=z3fold"
    "zswap.max_pool_percent=20"
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
  nix.settings.auto-optimise-store = true;

  programs.nh = {
    enable = true;
    flake = "/home/max/.config/nix";
    clean = {
      enable = true;
      dates = "*-*-1,15 03:15:00";
      extraArgs = "--keep 10 --keep-since 14d";
    };
  };

  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    defaultSopsFormat = "yaml";

    age.keyFile = "/home/max/.config/sops/age/keys.txt";

    secrets = {
      github-API = { };
    };

    templates."conf-access-tokens".content =
      "extra-access-tokens = github.com=${config.sops.placeholder.github-API}";
  };

  #nix.extraOptions = "!include ${config.sops.templates."conf-access-tokens".path}"; # Why cant this find the file???
  nix.extraOptions = (builtins.readFile config.sops.templates."conf-access-tokens".path);

  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    flake = "/home/max/.config/nix#nixos";
    flags = [ "--update-input" "nixpkgs" "-L" ];
    dates = "weekly";
    randomizedDelaySec = "45min";
  };

  networking.hostName = "nixos"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;
  networking.wireless.enable = false;
  # networking.wireless.userControlled.enable = true;
  # users.extraUsers.max.extraGroups = [ "wheel" ];

  # WireGuard tunnel
  sops.secrets.proton-wg = { };
  networking.wg-quick.interfaces.proton.configFile = config.sops.secrets.proton-wg.path;
  systemd.services."wg-quick-proton" = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
  };

  # Set your time zone.
  time.timeZone = "Europe/London";

  # Select internationalisation properties.
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

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Ignore lid closing
  services.logind.lidSwitch = "ignore";

  # Enable sound with pipewire.
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;

  # Configure console keymap
  console.keyMap = "uk";
  services.xserver.layout = "uk";
  hardware.keyboard.qmk.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.max = {
    isNormalUser = true;
    description = "Max Carroll";
    extraGroups = [
      "networkmanager"
      "wheel"
      "keys"
    ];
    packages = with pkgs; [
      kdePackages.kate
      #  thunderbird
    ];
  };

  nixpkgs.config.allowUnfree = true;

  # Install firefox.
  programs.firefox.enable = true;

  programs.hyprland.enable = true;
  programs.hyprland.withUWSM = true;
  programs.hyprland.package = inputs.hyprland.packages."${pkgs.system}".hyprland;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    #  vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    #  wget
    git
    vscode
    wayland-utils
    wl-clipboard
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?

}

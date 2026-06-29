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
    flags = [
      "--update-input"
      "nixpkgs"
      "--update-input"
      "nixpkgs-unstable"
      "-L"
    ];
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
  # networking.wireless.userControlled.enable = true;
  # users.extraUsers.max.extraGroups = [ "wheel" ];

  networking.networkmanager.unmanaged = [
    "interface-name:proton"
    "interface-name:proton-2"
  ];
  sops.secrets.proton-wg = { };
  sops.secrets.proton-wg-2 = { };
  networking.wg-quick.interfaces.proton = {
    configFile = config.sops.secrets.proton-wg.path;
    autostart = false;
  };
  networking.wg-quick.interfaces.proton-2.configFile = config.sops.secrets.proton-wg-2.path;
  systemd.services."wg-quick-proton" = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
    conflicts = [ "wg-quick-proton-2.service" ];
  };
  systemd.services."wg-quick-proton-2" = {
    after = [ "sops-install-secrets.service" ];
    wants = [ "sops-install-secrets.service" ];
    conflicts = [ "wg-quick-proton.service" ];
  };

  # Fail-closed VPN kill switch: drop all egress except loopback, the tunnel
  # interfaces, WireGuard's own marked packets, LAN, and DHCP. Active even
  # before a tunnel comes up, so the real IP can't leak in the boot race.
  # 0xca6c is the fwmark wg-quick puts on encrypted packets (table 51820);
  # 0xca6d covers a brief overlap if both tunnels race during a switch.
  networking.nftables.enable = true;
  networking.nftables.tables.vpn-killswitch = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority 0; policy drop;

        oifname "lo" accept
        oifname { "proton", "proton-2" } accept
        meta mark { 0xca6c, 0xca6d } accept

        udp dport { 67, 68 } accept
        ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 255.255.255.255, 224.0.0.0/4 } accept
        ip6 daddr { fe80::/10, ff00::/8 } accept

        counter drop
      }
    '';
  };

  # Split tunnel: traffic from the "novpn" group bypasses the VPN. Marking it
  # 0xca6c makes wg-quick's rules route it out the physical link instead of the
  # tunnel, and the kill switch above already accepts that mark. DNS stays on
  # the default path so it resolves via the tunnel's resolver while VPN is up.
  # The reroute happens after the socket already picked the tunnel source IP,
  # so masquerade rewrites it to the physical address (matched by skgid, not
  # the mark, to leave WireGuard's own encrypted packets untouched).
  users.groups.novpn.gid = 700;
  networking.nftables.tables.novpn-split = {
    family = "inet";
    content = ''
      chain output {
        type route hook output priority mangle; policy accept;

        meta skgid 700 udp dport 53 return
        meta skgid 700 tcp dport 53 return
        meta skgid 700 meta mark set 0xca6c
      }

      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        meta skgid 700 oifname != { "lo", "proton", "proton-2" } masquerade
      }
    '';
  };

  programs.firejail.enable = true;

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
      "novpn"
    ];
    packages = with pkgs; [
      kdePackages.kate
      #  thunderbird
    ];
  };

  nixpkgs.config.allowUnfree = true;

  # Install firefox from unstable.
  programs.firefox.enable = true;
  programs.firefox.package = pkgs-unstable.firefox;

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

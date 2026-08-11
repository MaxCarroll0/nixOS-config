# ThinkPad: workstation only, offloads builds to the desktop.

{ ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-env.nix
    ../../modules/nixos/vpn.nix
    ../../modules/nixos/wake.nix
    ../../modules/nixos/monitoring
    ../../modules/nixos/build-client.nix
    ../../modules/nixos/torrent.nix
    ../../modules/nixos/server/ssh.nix
    ../../modules/nixos/server/tailscale.nix
    ../../modules/nixos/server/build-host.nix
    ../../modules/nixos/pam-ssh-agent-sudo.nix
  ];

  networking.hostName = "laptop";

  networking.hosts."100.106.140.88" = [ "desktop.grafana" ];

  local.monitoring = {
    exporter.enable = true;
    userReadable = true;
    sensorNames = {
      "coretemp:temp1" = "CPU package";
      "nvme:temp1" = "NVMe";
      "acpitz:temp1" = "Ambient";
    };
  };

  local.vpn = {
    configs.uk = "proton-wg";
    primary = "uk";
  };

  local.torrent.enable = true;

  services.earlyoom = {
    freeMemThreshold = 15;
    freeSwapThreshold = 25;
    extraArgs = [
      "--prefer"
      "^firefox$"
      "--avoid"
      "^(sshd?|systemd|kwin_wayland|Hyprland|plasmashell)$"
    ];
  };

  # Enabling sshd is also what generates /etc/ssh/ssh_host_ed25519_key, which
  # sops.age.sshKeyPaths picks up by default.
  local.server.ssh = {
    enable = true;
    allowUsers = [ "max" ];
  };
  local.server.tailscale = {
    enable = true;
    ssh = true;
    authKeySecret = "tailscale-auth-key";
  };

  local.wake.peers.desktop = {
    mac = "70:85:c2:54:c6:89";
    broadcast = "192.168.200.255";
    address = "192.168.200.204";
    timeoutSeconds = 90;
  };
  users.users.max.openssh.authorizedKeys.keyFiles = [ ../../keys/max.pub ];

  boot.loader.grub.extraEntries = /* bash */ ''
    menuentry "Ubuntu iso" {
      insmod ext2
      set isofile="/ubuntu/ubuntu.iso"
      loopback loop (hd0,5)$isofile
      linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=$isofile quiet noeject noprompt splash
      initrd (loop)/casper/initrd
    }
  '';

  system.autoUpgrade.enable = true;

  local.build.host.emulatedSystems = [ "aarch64-linux" ];

  local.build.client = {
    enable = true;
    builders.desktop = {
      user = "max";
      port = 22;
      tailscaleSsh = true;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      maxJobs = 8;
      speedFactor = 4;
    };
  };
}

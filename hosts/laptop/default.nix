# ThinkPad: workstation only, offloads builds to the desktop.

{ ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-env.nix
    ../../modules/nixos/vpn.nix
    ../../modules/nixos/wake.nix
    ../../modules/nixos/build-client.nix
    ../../modules/nixos/server/ssh.nix
    ../../modules/nixos/server/tailscale.nix
  ];

  networking.hostName = "laptop";

  local.vpn = {
    configs.nl = "proton-wg-2";
    primary = "nl";
  };

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
    port = 2222;
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

  local.build.client = {
    enable = true;
    builderHost = "desktop";
    builderUser = "max";
    builderPort = 22;
    tailscaleSsh = true;
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    maxJobs = 8;
    speedFactor = 4;
  };
}

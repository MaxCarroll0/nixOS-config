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
  # Interim relay: only routes while the laptop is actually at home.
  local.server.tailscale = {
    enable = true;
    authKeySecret = "tailscale-auth-key";
    advertiseRoutes = [ "192.168.200.0/24" ];
  };

  local.wake.peers.desktop = {
    mac = null; # from `ip link` on the desktop
    broadcast = "192.168.200.255";
  };
  users.users.max.openssh.authorizedKeys.keyFiles = [ ../../keys/max.pub ];

  boot.loader.grub.extraEntries = ''
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
    maxJobs = 8;
    speedFactor = 4;
  };
}

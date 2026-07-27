# ThinkPad: workstation only, offloads builds to the desktop.

{ ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-env.nix
    ../../modules/nixos/vpn.nix
    ../../modules/nixos/build-client.nix
    ../../modules/nixos/server/ssh.nix
    ../../modules/nixos/server/tailscale.nix
  ];

  networking.hostName = "laptop";

  # Enabling sshd is also what generates /etc/ssh/ssh_host_ed25519_key, which
  # sops.age.sshKeyPaths picks up by default.
  local.server.ssh = {
    enable = true;
    allowUsers = [ "max" ];
  };
  local.server.tailscale.enable = true;
  users.users.max.openssh.authorizedKeys.keyFiles = [ ../../keys/max.pub ];

  # Kept alongside the host key until host-key decryption is proven on both
  # machines; sops-nix tries every configured identity.
  sops.age.keyFile = "/home/max/.config/sops/age/keys.txt";

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

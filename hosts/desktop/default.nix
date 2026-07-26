# AMD desktop: workstation plus remote builder, SSH host, and web origin.

{ ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-env.nix
    ../../modules/nixos/vpn.nix
    ../../modules/nixos/power.nix
    ../../modules/nixos/server/ssh.nix
    ../../modules/nixos/server/tailscale.nix
    ../../modules/nixos/server/build-host.nix
    ../../modules/nixos/server/web.nix
  ];

  networking.hostName = "desktop";

  # Secrets must decrypt before login, so the host key is the recipient.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  local.server.ssh.enable = true;
  local.server.tailscale.enable = true;

  # Enable once the laptop's root key exists; see TODO.md.
  local.build.host = {
    enable = false;
    authorizedKeys = [ ];
  };

  local.web.public = {
    enable = false;
    tunnelId = "";
    hostnames = { };
  };

  local.power = {
    monitoring.enable = true;
    idle.optimise = true;
    idle.policy = "always-on";
    # Fill from `ip link` and the BIOS Wake-on-LAN setting.
    wakeOnLan = {
      interface = null;
      mac = null;
    };
  };
}

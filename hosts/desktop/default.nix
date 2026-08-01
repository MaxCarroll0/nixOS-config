# AMD desktop: workstation plus remote builder, SSH host, and web origin.

{ ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-env.nix
    ../../modules/nixos/vpn.nix
    ../../modules/nixos/wake.nix
    ../../modules/nixos/power.nix
    ../../modules/nixos/storage.nix
    ../../modules/nixos/server/ssh.nix
    ../../modules/nixos/server/tailscale.nix
    ../../modules/nixos/server/build-host.nix
    ../../modules/nixos/server/web.nix
  ];

  networking.hostName = "desktop";

  local.server.ssh = {
    enable = true;
    allowUsers = [ "max" ];
  };
  local.server.tailscale = {
    enable = true;
    authKeySecret = "tailscale-auth-key";
  };
  users.users.max.openssh.authorizedKeys.keyFiles = [ ../../keys/max.pub ];

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

  local.storage = {
    spinDownRotational.enable = true;
    lazyMounts = { };
  };

  local.power = {
    monitoring.enable = true;
    idle.optimise = true;
    idle.policy = "autosuspend";
    # Fill from `ip link` and the BIOS Wake-on-LAN setting.
    wakeOnLan = {
      interface = null;
      mac = null;
    };
  };
}

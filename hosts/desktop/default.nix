# AMD desktop: workstation plus remote builder, SSH host, and web origin.

{ lib, ... }:

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

  swapDevices = lib.mkForce [
    {
      device = "/swapfile";
      size = 32 * 1024;
    }
  ];

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
    monitoring.userReadable = true;
    idle.optimise = true;
    idle.policy = "always-on";
    wakeOnLan = {
      interface = "enp6s0";
      mac = "70:85:c2:54:c6:89";
    };
  };
}

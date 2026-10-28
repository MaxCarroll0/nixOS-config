# Satisfactory start page for friends on a node share, and the restic store for its saves.

{ config, inputs, ... }:

let
  facts = import ../facts.nix;
in

{
  imports = [
    inputs.satisfactory.nixosModules.panel
    inputs.satisfactory.nixosModules.backupStore
  ];

  sops.secrets.satisfactory-remote-key.owner = "satisfactory-panel";
  sops.secrets.satisfactory-restic-htpasswd.owner = "restic";

  local.satisfactory.panel = {
    enable = true;
    address = facts.pi.tailscale;
    desktop = {
      address = facts.desktopnew.tailscale;
      wakeName = "desktopnew";
      sshPort = 2222;
    };
    sshKeyFile = config.sops.secrets.satisfactory-remote-key.path;
    wakePackage = config.local.wake.package;
  };

  local.satisfactory.backupStore = {
    enable = true;
    address = facts.pi.tailscale;
    htpasswdFile = config.sops.secrets.satisfactory-restic-htpasswd.path;
  };
}

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
    trustedProxies = [ "100.125.126.78" ];
    desktop = {
      address = facts.desktopnew.tailscale;
      wakeName = "desktopnew";
      sshPort = 2222;
      lastBackupFile = config.local.satisfactory.backupStore.stampFile;
    };
    minecraft = {
      enable = true;
      connectAddress = "79.72.87.71:25565";
      lastBackupFile = "/var/lib/nas-streams/minecraft.last";
      modsFile = "/var/lib/minecraft-mods/organfarm-minecraft-modpack.zip";
      backups = {
        view = config.local.nas.checkpoints.viewDir;
        user = "max";
      };
    };
    sshKeyFile = config.sops.secrets.satisfactory-remote-key.path;
    wakePackage = config.local.wake.package;
  };

  local.satisfactory.backupStore = {
    enable = true;
    address = facts.pi.tailscale;
    dataDir = "${config.local.nas.dataRoot}/backups/restic";
    htpasswdFile = config.sops.secrets.satisfactory-restic-htpasswd.path;
  };
}

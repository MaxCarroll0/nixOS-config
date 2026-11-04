# Game server start page for friends on a node share, with world downloads from the NAS streams.

{ config, inputs, ... }:

let
  facts = import ../facts.nix;
in

{
  imports = [ inputs.satisfactory.nixosModules.panel ];

  sops.secrets.satisfactory-remote-key.owner = "satisfactory-panel";

  users.users.satisfactory-saves = {
    isSystemUser = true;
    uid = 2777;
    group = "satisfactory-saves";
  };
  users.groups.satisfactory-saves.gid = 2777;

  local.satisfactory.panel = {
    enable = true;
    address = facts.pi.tailscale;
    trustedProxies = [ "100.125.126.78" ];
    desktop = {
      address = facts.desktopnew.tailscale;
      wakeName = "desktopnew";
      sshPort = 2222;
      lastBackupFile = "/var/lib/nas-streams/satisfactory.last";
      backups = {
        view = config.local.nas.checkpoints.viewDir;
        user = "satisfactory-saves";
      };
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
}

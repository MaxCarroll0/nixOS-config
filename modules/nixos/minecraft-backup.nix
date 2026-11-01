# Continuous Minecraft backup from the damien-fedora guest into the pi's NAS stream.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.minecraftBackup;
  facts = import ../../hosts/facts.nix;
in

{
  options.local.minecraftBackup = {
    enable = lib.mkEnableOption "continuous Minecraft backup to the NAS";
    domain = lib.mkOption {
      type = lib.types.str;
      default = "damien-fedora";
      description = "Libvirt domain running the server.";
    };
    serverDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/minecraft/neoforge";
      description = "Server directory inside the guest.";
    };
    subvolume = lib.mkOption {
      type = lib.types.str;
      default = "/home";
      description = "Guest btrfs subvolume holding serverDir.";
    };
    interval = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Seconds between flushed backup points.";
    };
    receiver = lib.mkOption {
      type = lib.types.str;
      default = "${facts.pi.tailscale}:8020";
      description = "NAS stream receiver address.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.minecraft-rcon-password = {
      sopsFile = ../../secrets/minecraft-rcon-password;
      format = "binary";
    };

    systemd.services.minecraft-backup = {
      wantedBy = [ "multi-user.target" ];
      after = [
        "nixvirt.service"
        "tailscaled.service"
      ];
      path = [ config.virtualisation.libvirtd.package ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          (lib.getExe pkgs.python3)
          "${./minecraft-backup.py}"
          "--domain"
          cfg.domain
          "--stream"
          "minecraft"
          "--server-dir"
          cfg.serverDir
          "--subvolume"
          cfg.subvolume
          "--snapshot-dir"
          "${cfg.subvolume}/.mc-backup"
          "--rcon-password-file"
          config.sops.secrets.minecraft-rcon-password.path
          "--receiver"
          cfg.receiver
          "--interval"
          (toString cfg.interval)
          "--state-dir"
          "/var/lib/minecraft-backup"
          "--blockdelta"
          "${./blockdelta.py}"
        ];
        StateDirectory = "minecraft-backup";
        Restart = "always";
        RestartSec = 30;
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };
  };
}

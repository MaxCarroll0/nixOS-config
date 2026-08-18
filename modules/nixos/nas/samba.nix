# NAS SMB shares: one private share per account, isolation enforced by the kernel.

{
  config,
  lib,
  ...
}:

let
  cfg = config.local.nas;

  shareOf = name: {
    path = "${cfg.dataRoot}/${name}";
    browseable = "yes";
    writable = "yes";
    "valid users" = name;
    "force user" = name;
    "force group" = name;
    "create mask" = "0600";
    "directory mask" = "0700";
    "vfs objects" = "recycle";
    "recycle:repository" = ".recycle/%Y-%m";
    "recycle:keeptree" = "yes";
    "recycle:versions" = "yes";
    "recycle:touch" = "yes";
    "recycle:exclude" = "*.tmp *.temp *.o *.obj ~$*";
  };
in

{
  options.local.nas.smb = {
    enable = lib.mkEnableOption "SMB shares for NAS accounts";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "tailscale0";
      description = "Interface SMB is reachable on; never the public interface.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.smb.enable) {
    services.samba = {
      enable = true;
      openFirewall = false;
      nmbd.enable = false;
      winbindd.enable = false;

      settings = {
        global = {
          "server string" = config.networking.hostName;
          "workgroup" = "WORKGROUP";
          "security" = "user";
          "map to guest" = "never";
          "guest ok" = "no";
          "restrict anonymous" = "2";
          "disable netbios" = "yes";
          "server min protocol" = "SMB3";
          "client min protocol" = "SMB3";
          "smb encrypt" = "required";
          "bind interfaces only" = "yes";
          "interfaces" = "lo ${cfg.smb.interface}";
          "load printers" = "no";
          "printing" = "bsd";
          "printcap name" = "/dev/null";
          "disable spoolss" = "yes";
          "unix extensions" = "no";
          "follow symlinks" = "no";
          "wide links" = "no";
        };
      }
      // lib.mapAttrs (name: _: shareOf name) cfg.accounts;
    };

    networking.firewall.interfaces.${cfg.smb.interface}.allowedTCPPorts = [ 445 ];

    systemd.services.samba-nmbd.serviceConfig = {
      After = "network-online.target";
      Wants = "network-online.target";
    };
  };
}

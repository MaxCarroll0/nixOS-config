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

    interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "tailscale0" ];
      description = "LAN and tailnet interfaces on which encrypted SMB is reachable.";
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
          # All three machines have hardware acceleration for AES-GCM.
          "server smb3 encryption algorithms" = "AES-128-GCM";
          "bind interfaces only" = "yes";
          "interfaces" = "lo ${lib.concatStringsSep " " cfg.smb.interfaces}";
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

    networking.firewall.interfaces = lib.genAttrs cfg.smb.interfaces (_: {
      allowedTCPPorts = [ 445 ];
    });

    systemd.services.samba-nmbd.serviceConfig = {
      After = "network-online.target";
      Wants = "network-online.target";
    };
  };
}

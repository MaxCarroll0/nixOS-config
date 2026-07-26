# Hardened sshd, reachable only over the tailnet.

{ config, lib, ... }:

let
  cfg = config.local.server.ssh;
in

{
  options.local.server.ssh = {
    enable = lib.mkEnableOption "sshd restricted to the tailnet";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "tailscale0";
      description = "The only interface on which port 22 is opened.";
    };

    userKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Authorized keys for the max account.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.openssh = {
      enable = true;
      openFirewall = false;
      hostKeys = [
        {
          path = "/etc/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        MaxAuthTries = 3;
        X11Forwarding = false;
        AllowAgentForwarding = false;
        AllowTcpForwarding = false;
        AllowUsers = [
          "max"
          "nixremote"
        ];
      };
      extraConfig = ''
        PerSourcePenalties yes
      '';
    };

    users.users.max.openssh.authorizedKeys.keys = cfg.userKeys;

    networking.firewall.allowedTCPPorts = [ ];
    networking.firewall.interfaces.${cfg.interface}.allowedTCPPorts = [ 22 ];
  };
}

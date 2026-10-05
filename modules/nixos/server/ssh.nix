# Hardened sshd, reachable only over the tailnet.

{ config, lib, ... }:

let
  cfg = config.local.server.ssh;

  hasKeys =
    name:
    let
      u = config.users.users.${name} or null;
    in
    u != null && (u.openssh.authorizedKeys.keys != [ ] || u.openssh.authorizedKeys.keyFiles != [ ]);

  keyless = lib.filter (n: !hasKeys n) cfg.allowUsers;

  lanAllowed = [ cfg.port ] ++ cfg.allowGlobalTCPPorts;

  portsOn =
    interface:
    let
      rules = config.networking.firewall.interfaces.${interface};
    in
    rules.allowedTCPPorts ++ rules.allowedUDPPorts;

  offTailnet = lib.filter (interface: interface != cfg.interface && interface != "lo") (
    lib.attrNames config.networking.firewall.interfaces
  );

  reachableOffTailnet = lib.concatMap (
    interface:
    let
      allowed = if lib.elem interface cfg.lanInterfaces then lanAllowed else [ ];
    in
    map (port: "${interface}:${toString port}") (
      lib.filter (port: !(lib.elem port allowed)) (portsOn interface)
    )
  ) offTailnet;
in

{
  options.local.server.ssh = {
    enable = lib.mkEnableOption "sshd restricted to the tailnet";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "tailscale0";
      description = "The only interface on which OpenSSH is allowed.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 22;
      description = "OpenSSH port.";
    };

    allowUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Accounts sshd accepts. Each needs authorized keys; password and root logins are off.";
    };

    allowGlobalTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "TCP ports allowed on every interface. Empty keeps the host tailnet-only.";
    };

    lanInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Local interfaces that also accept sshd, so a dead tailscaled is still reachable.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.openssh = {
      enable = true;
      openFirewall = false;
      ports = [ cfg.port ];
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
        AllowAgentForwarding = true;
        AllowTcpForwarding = false;
        AllowUsers = cfg.allowUsers;
      };
      extraConfig = ''
        PerSourcePenalties yes
      '';
    };

    networking.firewall.interfaces = {
      ${cfg.interface}.allowedTCPPorts = [ cfg.port ];
    }
    // lib.genAttrs cfg.lanInterfaces (_: {
      allowedTCPPorts = [ cfg.port ];
    });

    assertions = [
      {
        assertion = cfg.allowUsers != [ ];
        message = "local.server.ssh.allowUsers is empty, so sshd would accept nobody.";
      }
      {
        assertion = keyless == [ ];
        message = "In allowUsers but with no authorized keys, so they could never log in: ${lib.concatStringsSep ", " keyless}.";
      }
      {
        assertion = cfg.interface != "tailscale0" || config.services.tailscale.enable;
        message = "sshd is bound to tailscale0 but services.tailscale is off, so that interface never appears.";
      }
      {
        assertion = lib.all (
          p: lib.elem p cfg.allowGlobalTCPPorts
        ) config.networking.firewall.allowedTCPPorts;
        message = "Open on every interface, not just ${cfg.interface}: ${
          lib.concatMapStringsSep ", " toString (
            lib.filter (p: !(lib.elem p cfg.allowGlobalTCPPorts)) config.networking.firewall.allowedTCPPorts
          )
        }. Bind to loopback, move to networking.firewall.interfaces.${cfg.interface}, or list in allowGlobalTCPPorts.";
      }
      {
        assertion = reachableOffTailnet == [ ];
        message = "Reachable off ${cfg.interface}: ${lib.concatStringsSep ", " reachableOffTailnet}. Service ports belong on ${cfg.interface} so they are reachable only over the tailnet or a shared node; lanInterfaces carries sshd's recovery path alone.";
      }
    ];
  };
}

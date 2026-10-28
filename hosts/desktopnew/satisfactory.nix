# Satisfactory dedicated server, started from the pi's panel and backed up to the pi.

{ config, inputs, ... }:

let
  facts = import ../facts.nix;
in

{
  imports = [ inputs.satisfactory.nixosModules.server ];

  sops.secrets.satisfactory-admin-password = { };
  sops.secrets.satisfactory-restic-password = { };
  sops.secrets.satisfactory-restic-http-password = { };
  sops.templates.satisfactory-restic-repository.content = "rest:http://satisfactory:${config.sops.placeholder.satisfactory-restic-http-password}@${facts.pi.tailscale}:8010/satisfactory/";

  local.satisfactory.server = {
    enable = true;
    adminPasswordFile = config.sops.secrets.satisfactory-admin-password.path;
    resticPasswordFile = config.sops.secrets.satisfactory-restic-password.path;
    resticRepositoryFile = config.sops.templates.satisfactory-restic-repository.path;
    keepAwakePackage = config.local.power.keepAwakePackage;
    remote.authorizedKeys = [ (builtins.readFile ../../keys/satisfactory-remote.pub) ];
  };

  local.server.ssh.allowUsers = [ config.local.satisfactory.server.remote.user ];
}

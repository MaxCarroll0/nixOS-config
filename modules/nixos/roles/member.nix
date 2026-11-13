# Baseline every tailnet member host gets: tailscale, sshd, NAS and attic clients, exporter.

{
  lib,
  facts,
  ...
}:

{
  imports = [
    ../server/ssh.nix
    ../server/tailscale.nix
    ../nas/attic-client.nix
    ../nas/client.nix
    ../monitoring
  ];

  networking.hosts.${facts.pi.tailscale} = [
    "observatory"
    "grafana"
    "pi.grafana"
    "bookshelf"
    "books"
  ];

  local.nas.attic.client = {
    enable = true;
    publicKey = lib.removeSuffix "\n" (builtins.readFile ../../../keys/attic-public-key);
  };
  local.nas.client.enable = true;

  local.server.ssh = {
    enable = true;
    port = lib.mkDefault 2222;
    allowUsers = [ "max" ];
  };
  local.server.tailscale = {
    enable = true;
    ssh = true;
    authKeySecret = "tailscale-auth-key";
  };

  users.users.max.openssh.authorizedKeys.keyFiles = [ ../../../keys/max.pub ];

  local.monitoring = {
    exporter.enable = true;
    smart.enable = true;
    userReadable = true;
    telemetry.journalGateway.enable = true;
  };
}

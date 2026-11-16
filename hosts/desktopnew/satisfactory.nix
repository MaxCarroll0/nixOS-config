# Satisfactory dedicated server, started from the pi's panel and backed up to the pi.

{
  config,
  lib,
  pkgs,
  inputs,
  facts,
  ...
}:

{
  imports = [ inputs.satisfactory.nixosModules.server ];

  sops.secrets.satisfactory-admin-password = { };

  local.satisfactory.server = {
    enable = true;
    adminPasswordFile = config.sops.secrets.satisfactory-admin-password.path;
    streamUrl = "rsync://${facts.pi.tailscale}:8021/satisfactory/";
    keepAwakePackage = config.local.power.keepAwakePackage;
    remote.authorizedKeys = [ (builtins.readFile ../../keys/satisfactory-remote.pub) ];
  };

  local.vpn.selection.deferWhile = [
    (lib.getExe (
      pkgs.writeShellApplication {
        name = "satisfactory-occupied";
        runtimeInputs = [ pkgs.jq ];
        text = ''
          jq -e --argjson now "$(date +%s)" '(.players // 0) > 0 and $now - .updated < 180' /run/satisfactory/status.json >/dev/null 2>&1
        '';
      }
    ))
  ];

  local.server.ssh.allowUsers = [ config.local.satisfactory.server.remote.user ];
}

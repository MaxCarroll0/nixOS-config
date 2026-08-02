# VPN-bypass options, declared for every host so units can reference them
# whether or not vpn.nix (the killswitch itself) is imported.

{ lib, ... }:

{
  options.local.vpn = {
    bypassUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Systemd units whose sockets are marked 0xca6c, routing them out the
        physical link instead of the tunnel. The kill switch already accepts
        that mark, so marking is also what lets them out at all.
      '';
    };

    allowInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra output interfaces the kill switch accepts, for tunnels the host
        terminates itself (tailscale0). Traffic leaving this way is not marked,
        so it needs an explicit accept.
      '';
    };
  };

  config.users.groups.novpn.gid = 700;
}

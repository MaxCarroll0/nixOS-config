{
  pkgs,
  nixPackage,
}:

pkgs.writeShellApplication {
  name = "nix-daemon-novpn";
  text = ''
    exec /run/wrappers/bin/sg novpn -c 'exec ${nixPackage}/bin/nix-daemon --stdio'
  '';
}

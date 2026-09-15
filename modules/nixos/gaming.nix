# Steam with Proton, gamescope, GameMode and MangoHud.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.gaming;

  steamPkg = config.programs.steam.package;

  # sg -c takes a single command string, so argv has to be requoted into it.
  novpn = name: ''
    args=""
    if [ "$#" -gt 0 ]; then
      printf -v args ' %q' "$@"
    fi
    exec /run/wrappers/bin/sg novpn -c "${steamPkg}/bin/${name}$args"
  '';

  # hiPrio so this shadows the package's own bin/steam, which the desktop entry,
  # the steam:// handlers and the gamescope session all resolve off PATH.
  steamNovpn = lib.hiPrio (pkgs.writeShellScriptBin "steam" (novpn "steam"));

  steamVpn = pkgs.writeShellScriptBin "steam-vpn" ''
    exec ${steamPkg}/bin/steam "$@"
  '';
in

{
  options.local.gaming.enable = lib.mkEnableOption "Steam and the Proton runtime";

  config = lib.mkIf cfg.enable {
    programs.steam = {
      enable = true;
      gamescopeSession.enable = true;
      protontricks.enable = true;
      extraCompatPackages = [ pkgs.proton-ge-bin ];
      # extraLibraries feeds multiPkgs, so MangoHud gets a 32-bit build too.
      package = pkgs.steam.override { extraLibraries = p: [ p.mangohud ]; };
    };

    programs.gamescope.capSysNice = true;
    programs.gamemode.enable = true;

    environment.systemPackages = [
      steamNovpn
      steamVpn
      pkgs.mangohud
      pkgs.protonup-qt
    ];
  };
}

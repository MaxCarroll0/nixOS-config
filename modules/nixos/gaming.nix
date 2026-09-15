# Steam with Proton, gamescope, GameMode and MangoHud.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.gaming;

  # sg -c hands the inner shell no positional arguments, so the steam:// URL
  # has to arrive through the environment.
  steamNovpn = pkgs.writeShellScriptBin "steam-novpn" ''
    export STEAM_URL="''${1:-}"
    exec /run/wrappers/bin/sg novpn -c '${config.programs.steam.package}/bin/steam ''${STEAM_URL:+"$STEAM_URL"}'
  '';

  steamNovpnItem = pkgs.makeDesktopItem {
    name = "steam-novpn";
    desktopName = "Steam (no VPN)";
    exec = "steam-novpn %U";
    icon = "steam";
    categories = [ "Game" ];
    mimeTypes = [ "x-scheme-handler/steam" ];
  };
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
      steamNovpnItem
      pkgs.mangohud
      pkgs.protonup-qt
    ];
  };
}

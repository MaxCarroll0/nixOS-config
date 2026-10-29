# Steam with Proton, Heroic for Epic, Lutris with Wine, gamescope, GameMode and MangoHud.

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
  novpn = program: ''
    args=""
    if [ "$#" -gt 0 ]; then
      printf -v args ' %q' "$@"
    fi
    exec /run/wrappers/bin/sg novpn -c "${program}$args"
  '';

  # hiPrio so this shadows the package's own bin/steam, which the desktop entry,
  # the steam:// handlers and the gamescope session all resolve off PATH.
  steamNovpn = lib.hiPrio (pkgs.writeShellScriptBin "steam" (novpn "${steamPkg}/bin/steam"));

  heroicNovpn = lib.hiPrio (pkgs.writeShellScriptBin "heroic" (novpn (lib.getExe pkgs.heroic)));

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
      # extraLibraries feeds multiPkgs, so MangoHud gets a 32-bit build too, but
      # it contributes only the library: the Vulkan loader finds no layer without
      # the manifest that extraPkgs installs.
      package = pkgs.steam.override {
        extraLibraries = p: [ p.mangohud ];
        extraPkgs = p: [ p.mangohud ];
      };
    };

    systemd.user.tmpfiles.rules = [
      "L+ %h/.config/heroic/tools/proton/GE-Proton - - - - ${pkgs.proton-ge-bin.steamcompattool}"
    ];

    programs.gamescope.capSysNice = true;
    programs.gamemode.enable = true;

    # A game holds an idle inhibitor, never a sleep one, and a paused game drops
    # below the load threshold, so without this the idle watcher suspends it.
    programs.gamemode.settings =
      lib.mkIf ((config.local ? power) && config.local.power.idle.autosuspend.keepAwake)
        {
          custom = {
            start = "${lib.getExe config.local.power.keepAwakePackage} --take gamemode --why 'game running'";
            end = "${lib.getExe config.local.power.keepAwakePackage} --release gamemode";
          };
        };

    environment.systemPackages = [
      steamNovpn
      steamVpn
      pkgs.heroic
      heroicNovpn
      pkgs.protonup-qt
      pkgs.lutris
      pkgs.winetricks
      pkgs.wineWow64Packages.stagingFull
    ];
  };
}

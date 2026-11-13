# Steam with Proton, Heroic for Epic, Prism Launcher for Minecraft, Lutris with Wine, gamescope, GameMode and MangoHud.

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

  # hiPrio shadows the package's bin/steam, which desktop entries and gamescope resolve off PATH.
  steamNovpn = lib.hiPrio (pkgs.writeShellScriptBin "steam" (novpn "${steamPkg}/bin/steam"));

  heroicNovpn = lib.hiPrio (pkgs.writeShellScriptBin "heroic" (novpn (lib.getExe pkgs.heroic)));

  prismOfflineOwned = pkgs.prismlauncher.override {
    prismlauncher-unwrapped = pkgs.prismlauncher-unwrapped.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace launcher/minecraft/auth/MinecraftAccount.h \
          --replace-fail \
            "return data.type != AccountType::Offline && data.minecraftEntitlement.ownsMinecraft;" \
            "return data.type == AccountType::Offline || data.minecraftEntitlement.ownsMinecraft;"
      '';
    });
  };

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
      # MangoHud's 32-bit library needs the layer manifest that extraPkgs installs.
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

    # Games hold idle inhibitors, not sleep ones, and a paused game falls below the load threshold.
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
      prismOfflineOwned
      heroicNovpn
      pkgs.protonup-qt
      pkgs.lutris
      pkgs.winetricks
      pkgs.wineWow64Packages.stagingFull
    ];
  };
}

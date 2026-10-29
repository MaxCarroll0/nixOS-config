# Wallpaper rotation with a light/dusk/dark schedule and image-derived colour schemes.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.wallpaper;
  state = config.xdg.stateHome;

  settings = pkgs.writeText "wallpaper-theme.json" (
    builtins.toJSON {
      wallpaperDir = cfg.dir;
      inherit (cfg.location) latitude longitude;
      inherit (cfg) darkBy lightAt duskMinutes;
      skeletons = {
        light = config.local.theme.schemes.gruvbox-light-hard;
        dark = config.local.theme.schemes.gruvbox-dark-hard;
      };
      stateDir = "${state}/wallpaper-theme";
      cacheDir = "${config.xdg.cacheHome}/wallpaper-theme";
      inherit (cfg) schemeRoot;
      palettePath = config.local.theme.palettePath;
      themeApply = config.local.theme.applyCommand;
      caelestia = lib.getExe' config.programs.caelestia.cli.package "caelestia";
      caelestiaScheme = "${state}/caelestia/scheme.json";
      caelestiaWallpaper = "${state}/caelestia/wallpaper/path.txt";
    }
  );

  python = pkgs.python3.withPackages (ps: [
    ps.pillow
    ps.astral
  ]);

  wallpaperTheme = pkgs.writeShellApplication {
    name = "wallpaper-theme";
    text = ''
      WALLPAPER_THEME_CONFIG=${settings} exec ${python}/bin/python3 -I ${./wallpaper/wallpaper-theme.py} "$@"
    '';
  };
in
{
  options.local.wallpaper = {
    dir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Pictures/Wallpapers";
      description = "Wallpaper pool; light/, dusk/ and dark/ subfolders override classification.";
    };
    location = {
      latitude = lib.mkOption {
        type = lib.types.float;
        default = 51.51;
        description = "Latitude for the sunset time.";
      };
      longitude = lib.mkOption {
        type = lib.types.float;
        default = -0.13;
        description = "Longitude for the sunset time.";
      };
    };
    darkBy = lib.mkOption {
      type = lib.types.str;
      default = "21:00";
      description = "Latest time dark mode starts; dusk precedes it by twice duskMinutes.";
    };
    duskMinutes = lib.mkOption {
      type = lib.types.int;
      default = 90;
      description = "Dusk length either side of sunset.";
    };
    lightAt = lib.mkOption {
      type = lib.types.str;
      default = "06:00";
      description = "Time light mode resumes.";
    };
    schemeRoot = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${state}/wallpaper-theme/scheme";
      description = "Caelestia scheme directory the generated colours are written to.";
    };
  };

  config = lib.mkIf config.local.wm.enable {
    home.packages = [ wallpaperTheme ];

    systemd.user.services.wallpaper-theme-sync = {
      Unit = {
        Description = "Match the wallpaper and scheme to the time of day";
        After = [
          "hyprland-session.target"
          "caelestia.service"
        ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe wallpaperTheme} sync";
      };
      Install.WantedBy = [ "hyprland-session.target" ];
    };

    systemd.user.timers.wallpaper-theme-sync = {
      Unit = {
        Description = "Check the light/dusk/dark schedule";
        PartOf = [ "hyprland-session.target" ];
      };
      Timer.OnCalendar = "*:0/5";
      Install.WantedBy = [ "hyprland-session.target" ];
    };
  };
}

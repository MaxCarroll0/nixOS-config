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

  kittyColours = "${state}/wallpaper-theme/kitty.conf";

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
      inherit kittyColours;
      gtkSettings = map (v: "${config.xdg.configHome}/gtk-${v}/settings.ini") [
        "3.0"
        "4.0"
      ];
    }
  );

  python = pkgs.python3.withPackages (ps: [
    ps.pillow
    ps.astral
  ]);

  realesrgan = pkgs.realesrgan-ncnn-vulkan;

  wallpaperUpscale = pkgs.writeShellApplication {
    name = "wallpaper-upscale";
    runtimeInputs = [
      realesrgan
      pkgs.imagemagick
      pkgs.rsync
      pkgs.openssh
      pkgs.findutils
      pkgs.diffutils
      pkgs.util-linux
    ];
    runtimeEnv = {
      ORIGINALS = cfg.originals;
      POOL = cfg.dir;
      HOST = cfg.upscaleHost;
      REALESRGAN = "${realesrgan}";
      MODEL = "realesrgan-x4plus-anime";
      SIZE = "3840x2160^";
    };
    excludeShellChecks = [ "SC2029" ];
    text = builtins.readFile ./wallpaper/wallpaper-upscale.sh;
  };

  wallpaperTheme = pkgs.writeShellApplication {
    name = "wallpaper-theme";
    runtimeInputs = [
      pkgs.dconf
      pkgs.procps
    ];
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
    originals = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Pictures/WallpaperOriginals";
      description = "Unscaled source images kept by wallpaper-upscale.";
    };
    upscaleHost = lib.mkOption {
      type = lib.types.str;
      default = "desktopnew";
      description = "GPU host wallpaper-upscale runs Real-ESRGAN on before falling back to this one.";
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
    home.packages = [
      wallpaperTheme
      wallpaperUpscale
    ];

    programs.kitty.extraConfig = "include ${kittyColours}";

    home.activation.claudeAutoTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      f="${config.home.homeDirectory}/.claude.json"
      if [ -s "$f" ] && [ "$(${lib.getExe pkgs.jq} -r .theme "$f")" != auto ]; then
        ${lib.getExe pkgs.jq} '.theme = "auto"' "$f" > "$f.tmp"
        mv "$f.tmp" "$f"
      fi
    '';

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

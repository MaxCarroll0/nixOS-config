# Caelestia: the quickshell desktop shell and its Hyprland look, from upstream.

{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.local.wm;
  system = pkgs.stdenv.hostPlatform.system;
  hyprland = inputs.hyprland.packages.${system}.hyprland;

  shell =
    (inputs.caelestia-shell.packages.${system}.with-cli.override { inherit hyprland; }).overrideAttrs
      (old: {
        patches = (old.patches or [ ]) ++ [ ./patches/caelestia-wm.patch ];
        postPatch = (old.postPatch or "") + ''
          cp -r --no-preserve=mode ${../quickshell/caelestia}/. .
        '';
      });

  hyprModules = [
    "env"
    "general"
    "input"
    "misc"
    "animations"
    "decoration"
    "group"
    "rules"
    "gestures"
  ];

  schemeFile = "${config.xdg.stateHome}/caelestia/scheme.json";

  chromiumTheme = pkgs.writeShellApplication {
    name = "caelestia-chromium-theme";
    runtimeInputs = [
      pkgs.jq
      pkgs.procps
    ];
    text = ''
      policy="${config.xdg.stateHome}/caelestia/chromium-policy.json"
      [ -s "${schemeFile}" ] || exit 0
      jq -c '{BrowserThemeColor: ("#" + .colours.surface), BrowserColorScheme: (if .mode == "light" then "light" else "dark" end)}' \
        "${schemeFile}" > "$policy.tmp"
      mv "$policy.tmp" "$policy"
      if pgrep -x -u "$(id -u)" chromium > /dev/null; then
        ${pkgs.chromium}/bin/chromium --refresh-platform-policy --no-startup-window || true
      fi
    '';
  };

  hyprFiles = [
    "variables.lua"
    "utils/functions.lua"
    "utils/json.lua"
    "scheme/default.lua"
  ]
  ++ map (m: "hyprland/${m}.lua") hyprModules;
in
{
  imports = [ inputs.caelestia-shell.homeManagerModules.default ];

  options.local.wm.caelestia = {
    hyprModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = hyprModules;
      description = "Caelestia's Hyprland modules, required in order by hyprland.lua.";
    };
    vars = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          lib.types.int
          lib.types.bool
        ]
      );
      default = { };
      description = "Overrides of Caelestia's Hyprland variables.lua.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.caelestia = {
      enable = true;
      package = shell;
      systemd.target = "hyprland-session.target";
      cli = {
        enable = true;
        settings.theme = lib.genAttrs [
          "enableGtk"
          "enableQt"
          "enableHtop"
          "enableBtop"
          "enableNvtop"
          "enableZed"
          "enableChromium"
          "enableDiscord"
          "enableSpicetify"
          "enablePandora"
          "enableWarp"
          "enableCava"
        ] (_: false);
      };
    };

    # Caelestia's Auto resolves en_GB's imperial measurement system to Fahrenheit.
    home.activation.caelestiaUnits = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      f="${config.xdg.configHome}/caelestia/shell.json"
      mkdir -p "$(dirname "$f")"
      [ -s "$f" ] || echo '{}' > "$f"
      ${lib.getExe pkgs.jq} '.services.weatherUnits //= "Celsius" | .services.clockFormat //= "TwentyFourHour"' "$f" > "$f.tmp"
      mv "$f.tmp" "$f"
    '';

    home.pointerCursor = {
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
      size = 24;
      gtk.enable = true;
    };

    local.wm.caelestia.vars = {
      cursorTheme = config.home.pointerCursor.name;
      cursorSize = config.home.pointerCursor.size;
    };

    xdg.configFile = lib.listToAttrs (
      map (f: lib.nameValuePair "hypr/${f}" { source = "${inputs.caelestia-dots}/hypr/${f}"; }) hyprFiles
    );

    systemd.user.paths.caelestia-chromium-theme = {
      Unit.Description = "Watch the Caelestia scheme for Chromium";
      Path.PathChanged = schemeFile;
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.caelestia-chromium-theme = {
      Unit.Description = "Theme Chromium from the Caelestia scheme";
      Service = {
        Type = "oneshot";
        ExecStart = lib.getExe chromiumTheme;
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.hyprpolkitagent = {
      Unit = {
        Description = "Polkit authentication agent";
        PartOf = [ "hyprland-session.target" ];
        After = [ "hyprland-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent";
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "hyprland-session.target" ];
    };
  };
}

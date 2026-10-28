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

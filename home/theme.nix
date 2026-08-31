# Semantic colour palette: schemes emit roles, consumers read only roles.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.theme;

  paletteDir = "${config.xdg.stateHome}/theme";
  palettePath = "${paletteDir}/palette.json";
  schemeDir = "${config.xdg.configHome}/theme/schemes";

  themeApply = pkgs.writeShellScriptBin "theme-apply" ''
    set -u
    palette="''${1:-${palettePath}}"
    if [ ! -r "$palette" ]; then
      echo "theme-apply: no palette at $palette" >&2
      exit 1
    fi

    get() { ${pkgs.jq}/bin/jq -r --arg k "$1" '.[$k]' "$palette"; }
    bare() { get "$1" | ${pkgs.gnused}/bin/sed 's/^#//'; }

    if command -v hyprctl > /dev/null 2>&1 && hyprctl version > /dev/null 2>&1; then
      if [ "$(get polarity)" = light ]; then shadow=true; else shadow=false; fi
      hyprctl keyword general:col.active_border "rgb($(bare border-active))" > /dev/null
      hyprctl keyword general:col.inactive_border "rgb($(bare border-inactive))" > /dev/null
      hyprctl keyword decoration:shadow:enabled "$shadow" > /dev/null
      hyprctl keyword decoration:shadow:color "rgba($(bare fg-faint)55)" > /dev/null
    fi

    if command -v emacsclient > /dev/null 2>&1; then
      ${pkgs.coreutils}/bin/timeout 1 emacsclient \
        --eval "(when (fboundp 'wm-theme-reload) (wm-theme-reload \"$palette\"))" \
        > /dev/null 2>&1 || true
    fi
  '';

  themeSet = pkgs.writeShellScriptBin "theme-set" ''
    set -eu
    if [ $# -ne 1 ]; then
      echo "usage: theme-set SCHEME" >&2
      ${pkgs.coreutils}/bin/ls -1 ${schemeDir} 2> /dev/null \
        | ${pkgs.gnused}/bin/sed 's/\.json$//' >&2 || true
      exit 2
    fi
    src="${schemeDir}/$1.json"
    if [ ! -r "$src" ]; then
      echo "theme-set: unknown scheme $1" >&2
      exit 1
    fi
    ${pkgs.coreutils}/bin/mkdir -p ${paletteDir}
    ${pkgs.coreutils}/bin/cp "$src" ${palettePath}
    exec ${themeApply}/bin/theme-apply
  '';

  gruvboxLightHard = {
    polarity = "light";
    bg = "#f9f5d7";
    bg-alt = "#fbf1c7";
    surface = "#ebdbb2";
    overlay = "#d5c4a1";
    fg = "#3c3836";
    fg-dim = "#504945";
    fg-faint = "#7c6f64";
    border-active = "#af3a03";
    border-inactive = "#d5c4a1";
    sel-bg = "#d5c4a1";
    sel-fg = "#282828";
    accent = "#af3a03";
    accent-alt = "#076678";
    ok = "#79740e";
    info = "#076678";
    warn = "#b57614";
    error = "#9d0006";
    ansi0 = "#fbf1c7";
    ansi1 = "#cc241d";
    ansi2 = "#98971a";
    ansi3 = "#d79921";
    ansi4 = "#458588";
    ansi5 = "#b16286";
    ansi6 = "#689d6a";
    ansi7 = "#7c6f64";
    ansi8 = "#928374";
    ansi9 = "#9d0006";
    ansi10 = "#79740e";
    ansi11 = "#b57614";
    ansi12 = "#076678";
    ansi13 = "#8f3f71";
    ansi14 = "#427b58";
    ansi15 = "#3c3836";
  };

  gruvboxDarkHard = {
    polarity = "dark";
    bg = "#1d2021";
    bg-alt = "#282828";
    surface = "#3c3836";
    overlay = "#504945";
    fg = "#ebdbb2";
    fg-dim = "#d5c4a1";
    fg-faint = "#a89984";
    border-active = "#fe8019";
    border-inactive = "#504945";
    sel-bg = "#504945";
    sel-fg = "#fbf1c7";
    accent = "#fe8019";
    accent-alt = "#83a598";
    ok = "#b8bb26";
    info = "#83a598";
    warn = "#fabd2f";
    error = "#fb4934";
    ansi0 = "#282828";
    ansi1 = "#cc241d";
    ansi2 = "#98971a";
    ansi3 = "#d79921";
    ansi4 = "#458588";
    ansi5 = "#b16286";
    ansi6 = "#689d6a";
    ansi7 = "#a89984";
    ansi8 = "#928374";
    ansi9 = "#fb4934";
    ansi10 = "#b8bb26";
    ansi11 = "#fabd2f";
    ansi12 = "#83a598";
    ansi13 = "#d3869b";
    ansi14 = "#8ec07c";
    ansi15 = "#ebdbb2";
  };

  requiredRoles = builtins.attrNames gruvboxLightHard;
  missingRoles = name: lib.subtractLists (builtins.attrNames cfg.schemes.${name}) requiredRoles;
  incompleteSchemes = lib.filter (n: missingRoles n != [ ]) (builtins.attrNames cfg.schemes);
in
{
  options.local.theme = {
    scheme = lib.mkOption {
      type = lib.types.str;
      default = "gruvbox-light-hard";
      description = "Active scheme name, a key of local.theme.schemes.";
    };

    schemes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      default = {
        gruvbox-light-hard = gruvboxLightHard;
        gruvbox-dark-hard = gruvboxDarkHard;
      };
      description = "Colour schemes, each mapping every semantic role to a value.";
    };

    active = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = "Roles of the scheme named by local.theme.scheme.";
    };

    palettePath = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Runtime palette file that theme-apply reads.";
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.schemes ? ${cfg.scheme};
        message = "local.theme.scheme is ${cfg.scheme}, which is not in local.theme.schemes.";
      }
      {
        assertion = incompleteSchemes == [ ];
        message =
          "colour schemes missing roles: "
          + lib.concatMapStringsSep "; " (
            n: "${n} lacks ${lib.concatStringsSep ", " (missingRoles n)}"
          ) incompleteSchemes;
      }
    ];

    local.theme.active = cfg.schemes.${cfg.scheme} or gruvboxLightHard;
    local.theme.palettePath = palettePath;

    home.packages = [
      themeApply
      themeSet
    ];

    xdg.configFile = lib.mapAttrs' (
      name: roles: lib.nameValuePair "theme/schemes/${name}.json" { text = builtins.toJSON roles; }
    ) cfg.schemes;

    home.activation.seedPalette = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -e ${palettePath} ]; then
        run ${pkgs.coreutils}/bin/mkdir -p ${paletteDir}
        run ${pkgs.coreutils}/bin/cp ${schemeDir}/${cfg.scheme}.json ${palettePath}
      fi
    '';
  };
}

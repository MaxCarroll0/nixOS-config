# Window manager keymap: one attrset generating Hyprland binds, elisp and help data.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.wm;

  bindingType = lib.types.submodule {
    options = {
      mods = lib.mkOption {
        type = lib.types.str;
        default = "SUPER";
        description = "Hyprland modifier string, empty inside a submap.";
      };
      key = lib.mkOption {
        type = lib.types.str;
        description = "Hyprland key name.";
      };
      owner = lib.mkOption {
        type = lib.types.enum [
          "hyprland"
          "emacs"
          "bridge"
        ];
        description = "Which party dispatches this binding.";
      };
      dispatch = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Hyprland dispatcher, and the required fallback for bridge bindings.";
      };
      elisp = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Emacs function called for emacs and bridge bindings.";
      };
      desc = lib.mkOption {
        type = lib.types.str;
        description = "One-line description shown in the which-key panel.";
      };
      mark = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether this binding pushes the unified mark ring.";
      };
    };
  };

  submapType = lib.types.submodule {
    options = {
      mods = lib.mkOption {
        type = lib.types.str;
        default = "SUPER";
        description = "Modifier of the chord entering this submap.";
      };
      key = lib.mkOption {
        type = lib.types.str;
        description = "Key of the chord entering this submap.";
      };
      desc = lib.mkOption {
        type = lib.types.str;
        description = "Panel title for this submap.";
      };
      keys = lib.mkOption {
        type = lib.types.attrsOf bindingType;
        default = { };
        description = "Bindings active inside this submap.";
      };
    };
  };

  # bind = takes "movefocus, l"; hyprctl dispatch takes "movefocus l".
  cliForm =
    d:
    lib.concatStringsSep " " (
      lib.filter (s: s != "") (lib.splitString " " (lib.replaceStrings [ "," ] [ " " ] d))
    );

  emacsCall = pkgs.writeShellScriptBin "wm-emacs" ''
    set -u
    exec ${pkgs.coreutils}/bin/timeout ${cfg.emacsTimeout} emacsclient \
      --eval "(when (fboundp '$1) ($1))" > /dev/null 2>&1
  '';

  bridgeEntries = lib.filterAttrs (_: b: b.owner == "bridge") (
    cfg.keys // lib.concatMapAttrs (_: s: s.keys) cfg.submaps
  );

  wmDispatch = pkgs.writeShellScriptBin "wm-dispatch" ''
    set -u
    case "$1" in
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: b: ''
        ${name})
          elisp=${lib.escapeShellArg b.elisp}
          fallback=${lib.escapeShellArg (cliForm b.dispatch)}
          ;;
      '') bridgeEntries
    )}
      *)
        echo "wm-dispatch: unknown binding $1" >&2
        exit 2
        ;;
    esac

    handled=$(${pkgs.coreutils}/bin/timeout ${cfg.emacsTimeout} emacsclient \
      --eval "(if (and (fboundp '$elisp) ($elisp)) \"t\" \"nil\")" 2> /dev/null || true)

    if [ "$handled" = '"t"' ]; then
      exit 0
    fi
    exec hyprctl dispatch $fallback
  '';

  wmPanic = pkgs.writeShellScriptBin "wm-panic" ''
    set -u
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (_: b: ''
        hyprctl keyword unbind "${b.mods},${b.key}" > /dev/null
        hyprctl keyword bind "${b.mods},${b.key},${b.dispatch}" > /dev/null
      '') bridgeEntries
    )}
    echo "wm-panic: ${toString (lib.length (lib.attrNames bridgeEntries))} bridge bindings now dispatch directly"
  '';

  bindLine =
    b:
    let
      target =
        if b.owner == "hyprland" then
          b.dispatch
        else if b.owner == "emacs" then
          "exec, ${emacsCall}/bin/wm-emacs ${b.elisp}"
        else
          "exec, ${wmDispatch}/bin/wm-dispatch ${b.name}";
    in
    "bind = ${b.mods}, ${b.key}, ${target}";

  named = attrs: lib.mapAttrsToList (name: b: b // { inherit name; }) attrs;

  submapBlock = name: s: ''
    submap = ${name}
    ${lib.concatStringsSep "\n" (map bindLine (named s.keys))}
    bind = , escape, submap, reset
    bind = , catchall, submap, reset
    submap = reset
  '';

  bindsConf = pkgs.writeText "binds.conf" ''
    ${lib.concatStringsSep "\n" (map bindLine (named cfg.keys))}

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: s: "bind = ${s.mods}, ${s.key}, submap, ${name}") cfg.submaps
    )}

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList submapBlock cfg.submaps)}
  '';

  helpData = {
    root = lib.mapAttrs (_: b: {
      inherit (b)
        mods
        key
        desc
        owner
        mark
        ;
    }) cfg.keys;
    submaps = lib.mapAttrs (_: s: {
      inherit (s) mods key desc;
      keys = lib.mapAttrs (_: b: {
        inherit (b)
          mods
          key
          desc
          owner
          mark
          ;
      }) s.keys;
    }) cfg.submaps;
  };

  keysEl = pkgs.writeText "wm-keys.el" ''
    ;;; wm-keys.el --- generated from local.wm.keys -*- lexical-binding: t; -*-

    (defconst wm-keys-help '${lib.generators.toPretty { multiline = false; } helpData}
      "Keymap description generated by home/wm-keys.nix.")

    (defconst wm-keys-mark-pushing
      '(${
        lib.concatStringsSep " " (lib.mapAttrsToList (n: _: n) (lib.filterAttrs (_: b: b.mark) cfg.keys))
      })
      "Bindings that push the unified mark ring.")

    (provide 'wm-keys)
  '';

  allMaps = [
    {
      label = "root";
      keys = cfg.keys;
    }
  ]
  ++ lib.mapAttrsToList (name: s: {
    label = "submap ${name}";
    keys = s.keys;
  }) cfg.submaps;

  chordsOf = keys: lib.mapAttrsToList (_: b: "${b.mods}, ${b.key}") keys;
  dupesIn =
    keys:
    let
      c = chordsOf keys;
    in
    lib.unique (lib.filter (k: lib.count (x: x == k) c > 1) c);
  mapsWithDupes = lib.filter (m: dupesIn m.keys != [ ]) allMaps;

  everyBinding = lib.concatMap (m: named m.keys) allMaps;
  allNames = map (b: b.name) everyBinding;
  dupeNames = lib.unique (lib.filter (n: lib.count (x: x == n) allNames > 1) allNames);
  bridgeNoFallback = lib.filter (b: b.owner == "bridge" && b.dispatch == null) everyBinding;
  emacsNoElisp = lib.filter (
    b: (b.owner == "emacs" || b.owner == "bridge") && b.elisp == null
  ) everyBinding;
  hyprNoDispatch = lib.filter (b: b.owner == "hyprland" && b.dispatch == null) everyBinding;
in
{
  options.local.wm = {
    enable = lib.mkEnableOption "the Emacs-native Hyprland desktop";

    emacsTimeout = lib.mkOption {
      type = lib.types.str;
      default = "0.15";
      description = "Seconds a keybind may wait on Emacs before falling back.";
    };

    keys = lib.mkOption {
      type = lib.types.attrsOf bindingType;
      default = { };
      description = "Flat hot-path bindings.";
    };

    submaps = lib.mkOption {
      type = lib.types.attrsOf submapType;
      default = { };
      description = "Prefix submaps and their bindings.";
    };

    bindsConf = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "Generated Hyprland bind fragment, for source =.";
    };
  };

  config = {
    assertions = [
      {
        assertion = mapsWithDupes == [ ];
        message =
          "duplicate keybind chords: "
          + lib.concatMapStringsSep "; " (
            m: "${m.label} repeats ${lib.concatStringsSep ", " (dupesIn m.keys)}"
          ) mapsWithDupes;
      }
      {
        assertion = dupeNames == [ ];
        message =
          "binding names must be unique across root and submaps, wm-dispatch keys on them: "
          + lib.concatStringsSep ", " dupeNames;
      }
      {
        assertion = bridgeNoFallback == [ ];
        message =
          "bridge bindings must declare a pure-Hyprland fallback in dispatch: "
          + lib.concatMapStringsSep ", " (b: b.name) bridgeNoFallback;
      }
      {
        assertion = emacsNoElisp == [ ];
        message =
          "bindings owned by emacs or bridge need elisp: "
          + lib.concatMapStringsSep ", " (b: b.name) emacsNoElisp;
      }
      {
        assertion = hyprNoDispatch == [ ];
        message =
          "hyprland bindings need dispatch: " + lib.concatMapStringsSep ", " (b: b.name) hyprNoDispatch;
      }
    ];

    local.wm.bindsConf = bindsConf;

    home.packages = lib.mkIf cfg.enable [
      emacsCall
      wmDispatch
      wmPanic
    ];

    xdg.configFile."emacs/wm-keys.el".source = keysEl;
    xdg.configFile."wm/help.json".text = builtins.toJSON helpData;
  };
}

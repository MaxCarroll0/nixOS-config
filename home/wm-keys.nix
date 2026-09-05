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
        description = "Lua dispatcher expression, and the required fallback for bridge bindings.";
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

  panicFlag = "\${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}/wm-bridge/panic";

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
          fallback=${lib.escapeShellArg b.dispatch}
          ;;
      '') bridgeEntries
    )}
      *)
        echo "wm-dispatch: unknown binding $1" >&2
        exit 2
        ;;
    esac

    if [ ! -e "${panicFlag}" ]; then
      handled=$(${pkgs.coreutils}/bin/timeout ${cfg.emacsTimeout} emacsclient \
        --eval "(if (and (fboundp '$elisp) ($elisp)) \"t\" \"nil\")" 2> /dev/null || true)
      if [ "$handled" = '"t"' ]; then
        exit 0
      fi
    fi
    exec hyprctl dispatch "$fallback"
  '';

  wmPanic = pkgs.writeShellScriptBin "wm-panic" ''
    set -u
    flag="${panicFlag}"
    if [ "''${1:-on}" = off ]; then
      ${pkgs.coreutils}/bin/rm -f "$flag"
      echo "wm-panic: off, bridge bindings consult Emacs again"
    else
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$flag")"
      ${pkgs.coreutils}/bin/touch "$flag"
      echo "wm-panic: on, ${toString (lib.length (lib.attrNames bridgeEntries))} bridge bindings now dispatch directly"
    fi
  '';

  luaStr = s: "\"" + lib.escape [ "\\" "\"" ] s + "\"";

  luaExec = cmd: "hl.dsp.exec_cmd(${luaStr cmd})";

  keySpec =
    b: lib.concatStringsSep "+" (lib.filter (s: s != "") (lib.splitString " " b.mods) ++ [ b.key ]);

  bindLine =
    b:
    let
      target =
        if b.owner == "hyprland" then
          b.dispatch
        else if b.owner == "emacs" then
          luaExec "${emacsCall}/bin/wm-emacs ${b.elisp}"
        else
          luaExec "${wmDispatch}/bin/wm-dispatch ${b.name}";
    in
    "hl.bind(${luaStr (keySpec b)}, ${target}, { description = ${luaStr b.desc} })";

  named = attrs: lib.mapAttrsToList (name: b: b // { inherit name; }) attrs;

  submapBlock = name: s: ''
    hl.define_submap(${luaStr name}, function()
    ${lib.concatStringsSep "\n" (map (b: "  " + bindLine b) (named s.keys))}
      hl.bind("escape", hl.dsp.submap("reset"))
      hl.bind("catchall", hl.dsp.submap("reset"))
    end)
  '';

  bindsLua = pkgs.writeText "binds.lua" ''
    ${lib.concatStringsSep "\n" (map bindLine (named cfg.keys))}

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: s:
        "hl.bind(${luaStr (keySpec s)}, hl.dsp.submap(${luaStr name}), { description = ${luaStr s.desc} })"
      ) cfg.submaps
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

  toElisp =
    v:
    if lib.isBool v then
      (if v then "t" else "nil")
    else if lib.isInt v || lib.isFloat v then
      toString v
    else if lib.isString v then
      "\"" + lib.escape [ "\\" "\"" ] v + "\""
    else if lib.isList v then
      "(" + lib.concatMapStringsSep " " toElisp v + ")"
    else if lib.isAttrs v then
      "(" + lib.concatStringsSep " " (lib.mapAttrsToList (k: x: "(${k} . ${toElisp x})") v) + ")"
    else
      throw "toElisp: unsupported value";

  helpJson = pkgs.writeText "wm-help.json" (builtins.toJSON helpData);

  cheatsheet = pkgs.writeShellScriptBin "wm-cheatsheet" ''
    set -u
    ${pkgs.jq}/bin/jq -r '
      (.root    | to_entries[] | "\(.value.mods)+\(.value.key)|\(.value.desc)"),
      (.submaps | to_entries[] as $s | $s.value.keys | to_entries[]
                | "\($s.value.mods)+\($s.value.key) then \(.value.mods // "")\(if (.value.mods // "") == "" then "" else "+" end)\(.value.key)|\(.value.desc)")
    ' ${helpJson} \
      | ${pkgs.gnused}/bin/sed 's/^+//' \
      | ${pkgs.coreutils}/bin/sort \
      | ${pkgs.util-linux}/bin/column -t -s'|' \
      | rofi -dmenu -i -p "keybinds" -theme-str 'window {width: 60%;}' > /dev/null
  '';

  keysEl = pkgs.writeText "wm-keys.el" ''
    ;;; wm-keys.el --- generated from local.wm.keys -*- lexical-binding: t; -*-

    (defconst wm-keys-help '${toElisp helpData}
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

    panicCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Absolute path of wm-panic, for binds that cannot rely on PATH.";
    };

    cheatsheetCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Absolute path of wm-cheatsheet.";
    };

    bindsFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "Generated Lua bind fragment, loaded with dofile.";
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

    local.wm.bindsFile = bindsLua;
    local.wm.panicCommand = "${wmPanic}/bin/wm-panic";
    local.wm.cheatsheetCommand = "${cheatsheet}/bin/wm-cheatsheet";

    home.packages = lib.mkIf cfg.enable [
      emacsCall
      wmDispatch
      wmPanic
      cheatsheet
    ];

    xdg.configFile."emacs/wm-keys.el".source = keysEl;
    xdg.configFile."wm/help.json".source = helpJson;
  };
}

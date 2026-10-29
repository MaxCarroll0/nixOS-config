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
      insert = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the binding hands the keyboard to an application, leaving NORMAL.";
      };
      flags = lib.mkOption {
        type = lib.types.listOf (
          lib.types.enum [
            "locked"
            "repeating"
            "release"
          ]
        );
        default = [ ];
        description = "Hyprland bind flags.";
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
      sticky = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the submap stays active after a binding fires, for repeatable keys.";
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
    cfg.keys // cfg.keypad // lib.concatMapAttrs (_: s: s.keys) cfg.submaps
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

  bindTarget =
    b:
    if b.owner == "hyprland" then
      b.dispatch
    else if b.owner == "emacs" then
      luaExec "${emacsCall}/bin/wm-emacs ${b.elisp}"
    else
      luaExec "${wmDispatch}/bin/wm-dispatch ${b.name}";

  bindWith =
    target: b:
    "hl.bind(${luaStr (keySpec b)}, ${target}, { description = ${luaStr b.desc}"
    + lib.concatMapStrings (f: ", ${f} = true") b.flags
    + " })";

  bindLine = b: bindWith (bindTarget b) b;

  submapTo = name: "hl.dsp.submap(${luaStr name})";

  oneShotTo =
    exit: b: bindWith "function() hl.dispatch(${submapTo exit}); hl.dispatch(${bindTarget b}) end" b;

  named = attrs: lib.mapAttrsToList (name: b: b // { inherit name; }) attrs;

  modsOf = b: lib.filter (s: s != "") (lib.splitString " " b.mods);
  withoutSuper = b: b // { mods = lib.concatStringsSep " " (lib.remove "SUPER" (modsOf b)); };
  chordId = b: "${lib.concatStringsSep " " (modsOf b)}|${b.key}";

  plainSuper =
    b:
    let
      m = modsOf b;
    in
    lib.elem "SUPER" m && !(lib.elem "CTRL" m) && !(lib.elem "ALT" m);

  normalReserved = [
    "|escape"
    "|i"
    "|space"
  ]
  ++ lib.mapAttrsToList (_: s: chordId (withoutSuper s)) cfg.submaps;

  normalBare = lib.filter (b: !(lib.elem (chordId b) normalReserved)) (
    map withoutSuper (lib.filter plainSuper (named cfg.keys))
  );

  inNormal = name: "normal:${name}";
  exitFor = context: if context == "normal" then "normal" else "reset";
  nameIn = context: name: if context == "normal" then inNormal name else name;

  entryLine =
    s: target:
    bindWith (submapTo target) {
      inherit (s) mods key desc;
      flags = [ ];
    };

  closeLines = exit: ''
    hl.bind("escape", ${submapTo exit})
      hl.bind("BackSpace", ${submapTo exit})
      hl.bind(${luaStr leaderKey}, ${submapTo "normal"})
      hl.bind("catchall", ${submapTo exit})
  '';

  normalLine = b: if b.insert then oneShotTo "reset" b else bindLine b;

  prefixLine =
    context: s: b:
    if context == "normal" && b.insert then
      oneShotTo "reset" b
    else if s.sticky then
      bindLine b
    else
      oneShotTo (exitFor context) b;

  prefixBlock = context: name: s: ''
    hl.define_submap(${luaStr (nameIn context name)}, function()
    ${lib.concatStringsSep "\n" (map (b: "  " + prefixLine context s b) (named s.keys))}
      ${closeLines (exitFor context)}
    end)
  '';

  leaderKey = "code:66";

  mouseInputs = map (b: "mouse:${toString b}") (lib.range 272 276) ++ [
    "mouse_up"
    "mouse_down"
    "mouse_left"
    "mouse_right"
  ];

  leaderLua = ''
    local wm_border = hl.get_config("general.border_size") or 1
    wm_leader_pending = false

    function wm_leader_ack(enter_normal)
      wm_leader_pending = false
      if enter_normal then
        return hl.dsp.submap("normal")
      end
      return hl.dsp.no_op()
    end

    local function wm_leader()
      local window = hl.get_active_window()
      if window and window.fullscreen >= 2 then
        hl.dispatch(hl.dsp.send_shortcut({ mods = "", key = "Escape" }))
      elseif window and window.class == "emacs" then
        wm_leader_pending = true
        hl.dispatch(hl.dsp.send_shortcut({ mods = "SUPER", key = "F12" }))
        hl.timer(function()
          if wm_leader_pending then
            wm_leader_pending = false
            hl.dispatch(hl.dsp.submap("normal"))
          end
        end, { timeout = 150, type = "oneshot" })
      else
        hl.dispatch(hl.dsp.submap("normal"))
      end
    end

    local function in_apps(name)
      return name == nil or name == "" or name == "default" or name == "reset"
    end

    hl.on("keybinds.submap", function(name)
      hl.config({ ["general.border_size"] = in_apps(name) and wm_border or wm_border + 2 })
    end)

    local function insert_when_fullscreen()
      local window = hl.get_active_window()
      if window and window.fullscreen >= 2 and not in_apps(hl.get_current_submap()) then
        hl.dispatch(hl.dsp.submap("reset"))
      end
    end

    hl.on("window.fullscreen", insert_when_fullscreen)
    hl.on("window.active", insert_when_fullscreen)
  '';

  toApps = desc: extra: "${submapTo "reset"}, { description = ${luaStr desc}${extra} }";

  normalBlock = ''
    hl.define_submap("normal", function()
    ${lib.concatStringsSep "\n" (map (b: "  " + normalLine b) (named cfg.keys))}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: s: "  " + entryLine s (inNormal name)) cfg.submaps
    )}
    ${lib.concatStringsSep "\n" (map (b: "  " + normalLine b) normalBare)}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: s: "  " + entryLine (withoutSuper s) (inNormal name)) cfg.submaps
    )}
      hl.bind("space", ${submapTo "normal:keypad"}, { description = "keypad" })
      hl.bind("escape", ${toApps "back to apps" ""})
      hl.bind("i", ${toApps "back to apps" ""})
      hl.bind(${luaStr leaderKey}, hl.dsp.no_op(), { description = "stay in NORMAL" })
      hl.bind("SUPER+escape", ${toApps "back to apps" ""})
    ${lib.concatMapStringsSep "\n" (
      m: "  hl.bind(${luaStr m}, hl.dsp.no_op(), { non_consuming = true })"
    ) mouseInputs}
      hl.bind("catchall", hl.dsp.no_op())
    end)
  '';

  keypadBlock = ''
    hl.define_submap("normal:keypad", function()
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: s: "  " + entryLine (withoutSuper s) (inNormal name)) cfg.submaps
    )}
    ${lib.concatStringsSep "\n" (
      map (b: "  " + oneShotTo (if b.insert then "reset" else "normal") b) (named cfg.keypad)
    )}
      ${closeLines "normal"}
    end)
  '';

  bindsLua = pkgs.writeText "binds.lua" ''
    ${lib.concatStringsSep "\n" (map bindLine (named cfg.keys))}

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: s: entryLine s name) cfg.submaps)}

    ${leaderLua}
    hl.bind(${luaStr leaderKey}, wm_leader, { description = "NORMAL state" })
    hl.bind("SUPER+escape", ${submapTo "normal"}, { description = "NORMAL state" })

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (prefixBlock "global") cfg.submaps)}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (prefixBlock "normal") cfg.submaps)}
    ${normalBlock}
    ${keypadBlock}
  '';

  shortName =
    name:
    lib.foldl' (n: p: lib.removePrefix p n) name [
      "kp-"
      "win-"
      "mon-"
      "prj-"
      "ses-"
      "grab-"
    ];
  entryOf = b: {
    inherit (b) mods key insert;
    desc = shortName b.name;
    prefix = false;
  };
  prefixEntryOf = s: {
    inherit (withoutSuper s) mods key;
    desc = s.name;
    prefix = true;
    insert = false;
  };
  normalLabel = {
    label = "NORMAL";
  };
  keypadKey = {
    mods = "";
    key = "space";
  };

  modes =
    lib.mapAttrs (name: s: {
      title = name;
      inherit (s) sticky;
      path = [ { inherit (s) mods key; } ];
      entries = map entryOf (named s.keys);
    }) cfg.submaps
    // lib.mapAttrs' (
      name: s:
      lib.nameValuePair (inNormal name) {
        title = name;
        inherit (s) sticky;
        path = [
          normalLabel
          { inherit (withoutSuper s) mods key; }
        ];
        entries = map entryOf (named s.keys);
      }
    ) cfg.submaps
    // {
      normal = {
        title = "NORMAL";
        sticky = true;
        path = [ normalLabel ];
        entries =
          map entryOf normalBare
          ++ map prefixEntryOf (named cfg.submaps)
          ++ [
            (
              keypadKey
              // {
                desc = "keypad";
                prefix = true;
                insert = false;
              }
            )
            {
              mods = "";
              key = "i";
              desc = "insert";
              prefix = false;
              insert = true;
            }
          ];
      };
      "normal:keypad" = {
        title = "keypad";
        sticky = false;
        path = [
          normalLabel
          keypadKey
        ];
        entries = map prefixEntryOf (named cfg.submaps) ++ map entryOf (named cfg.keypad);
      };
    };

  helpData = {
    root = lib.mapAttrs (name: b: {
      inherit (b)
        mods
        key
        owner
        mark
        ;
      desc = shortName name;
    }) cfg.keys;
    submaps = lib.mapAttrs (sname: s: {
      inherit (s) mods key;
      desc = sname;
      keys = lib.mapAttrs (name: b: {
        inherit (b)
          mods
          key
          owner
          mark
          ;
        desc = shortName name;
      }) s.keys;
    }) cfg.submaps;
    keypad = lib.mapAttrs (name: b: {
      inherit (b)
        mods
        key
        owner
        mark
        ;
      desc = shortName name;
    }) cfg.keypad;
    inherit modes;
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
  }) cfg.submaps
  ++ [
    {
      label = "keypad";
      keys = cfg.keypad;
    }
  ];

  prefixChords = lib.mapAttrs (_: withoutSuper) cfg.submaps;
  chordOnlyMaps = [
    {
      label = "keypad with its prefixes";
      keys = cfg.keypad // prefixChords;
    }
    {
      label = "global with its prefixes";
      keys = cfg.keys // cfg.submaps;
    }
  ];

  chordsOf = keys: lib.mapAttrsToList (_: b: "${b.mods}, ${b.key}") keys;
  dupesIn =
    keys:
    let
      c = chordsOf keys;
    in
    lib.unique (lib.filter (k: lib.count (x: x == k) c > 1) c);
  mapsWithDupes = lib.filter (m: dupesIn m.keys != [ ]) (allMaps ++ chordOnlyMaps);

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
      description = "Prefix submaps, entered by chord, by bare key in NORMAL, and from the keypad.";
    };

    keypad = lib.mkOption {
      type = lib.types.attrsOf bindingType;
      default = { };
      description = "Keypad bindings reached with SPC in NORMAL, alongside the prefix submaps.";
    };

    panicCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Absolute path of wm-panic, for binds that cannot rely on PATH.";
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
    home.packages = lib.mkIf cfg.enable [
      emacsCall
      wmDispatch
      wmPanic
    ];

    xdg.configFile."emacs/wm-keys.el".source = keysEl;
    xdg.configFile."wm/help.json".source = helpJson;
    systemd.user.services.caelestia.Unit.X-Restart-Triggers = [ "${helpJson}" ];
  };
}

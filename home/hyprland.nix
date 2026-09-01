# Hyprland session: core scrolling layout, palette-driven decoration, generated keybinds.

{
  config,
  lib,
  ...
}:

let
  cfg = config.local.wm;
  c = config.local.theme.active;

  rgb = v: "rgb(${lib.removePrefix "#" v})";
  rgba = alpha: v: "rgba(${lib.removePrefix "#" v}${alpha})";

  light = c.polarity == "light";

  emacsMatch = "class:^(emacs)$";

  luaStr = s: "\"" + lib.escape [ "\\" "\"" ] s + "\"";
  luaVal =
    v:
    if lib.isBool v then
      (if v then "true" else "false")
    else if lib.isInt v || lib.isFloat v then
      toString v
    else
      luaStr (toString v);

  hyprSettings = {
    "general.gaps_in" = 0;
    "general.gaps_out" = 40;
    "general.border_size" = 3;
    "general.col.active_border" = rgb c."border-active";
    "general.col.inactive_border" = rgb c."border-inactive";
    "general.layout" = "scrolling";
    "general.allow_tearing" = false;

    "scrolling.column_width" = 0.5;
    "scrolling.explicit_column_widths" = "0.333, 0.5, 0.667, 1.0";
    "scrolling.focus_fit_method" = 1;
    "scrolling.fullscreen_on_one_column" = true;
    "scrolling.follow_focus" = true;

    "decoration.rounding" = 7;
    "decoration.inactive_opacity" = 0.99;
    "decoration.blur.enabled" = true;
    "decoration.blur.size" = 1;
    "decoration.blur.passes" = 2;
    "decoration.blur.vibrancy" = 0.1696;
    "decoration.shadow.enabled" = light;
    "decoration.shadow.range" = 7;
    "decoration.shadow.render_power" = 9;
    "decoration.shadow.color" = rgba "aa" c."fg-faint";

    "input.kb_layout" = "gb";
    "input.kb_options" = "caps:escape";
    "input.follow_mouse" = 0;

    "misc.disable_hyprland_logo" = true;
    "misc.force_default_wallpaper" = 0;
  };

  curves = {
    easeOutQuint = [
      0.23
      1
      0.32
      1
    ];
    almostLinear = [
      0.5
      0.5
      0.75
      1.0
    ];
    quick = [
      0.15
      0
      0.1
      1
    ];
    fakeElastic = [
      0.68
      (-0.1)
      0.265
      1
    ];
    xfcBezier = [
      0.1
      0.9
      0.1
      1.03
    ];
  };

  animations = [
    {
      leaf = "windows";
      speed = 4.79;
      bezier = "easeOutQuint";
    }
    {
      leaf = "windowsIn";
      speed = 4;
      bezier = "easeOutQuint";
      style = "slide bottom";
    }
    {
      leaf = "windowsOut";
      speed = 8;
      bezier = "easeOutQuint";
      style = "slide top";
    }
    {
      leaf = "windowsMove";
      speed = 3;
      bezier = "fakeElastic";
      style = "slide";
    }
    {
      leaf = "border";
      speed = 1.39;
      bezier = "easeOutQuint";
    }
    {
      leaf = "fade";
      speed = 3.03;
      bezier = "quick";
    }
    {
      leaf = "layers";
      speed = 3.81;
      bezier = "easeOutQuint";
    }
    {
      leaf = "layersIn";
      speed = 4;
      bezier = "easeOutQuint";
      style = "fade";
    }
    {
      leaf = "layersOut";
      speed = 1.5;
      bezier = "almostLinear";
      style = "fade";
    }
    {
      leaf = "workspaces";
      speed = 4;
      bezier = "xfcBezier";
    }
  ];

  windowRules = [
    [
      "noshadow"
      emacsMatch
    ]
    [
      "bordersize 0"
      emacsMatch
    ]
    [
      "rounding 0"
      emacsMatch
    ]
  ];

  curveLine =
    name: p:
    "hl.curve(${luaStr name}, { type = \"bezier\", points = { "
    + "{${toString (lib.elemAt p 0)}, ${toString (lib.elemAt p 1)}}, "
    + "{${toString (lib.elemAt p 2)}, ${toString (lib.elemAt p 3)}} } })";

  animationLine =
    a:
    "hl.animation({ leaf = ${luaStr a.leaf}, enabled = true, speed = ${toString a.speed}"
    + ", bezier = ${luaStr a.bezier}"
    + (if a ? style then ", style = ${luaStr a.style}" else "")
    + " })";

  settingsLua = ''
    hl.config({
    ${lib.concatStringsSep ",\n" (
      lib.mapAttrsToList (k: v: "  [${luaStr k}] = ${luaVal v}") hyprSettings
    )}
    })

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList curveLine curves)}

    ${lib.concatStringsSep "\n" (map animationLine animations)}

    ${lib.concatStringsSep "\n" (
      map (r: "hl.window_rule({ ${luaStr (lib.elemAt r 0)}, ${luaStr (lib.elemAt r 1)} })") windowRules
    )}
  '';

  dirs = {
    h = "l";
    j = "d";
    k = "u";
    l = "r";
  };

  focusKeys = lib.mapAttrs' (
    key: dir:
    lib.nameValuePair "focus-${dir}" {
      inherit key;
      owner = "bridge";
      elisp = "wm-focus-${dir}";
      dispatch = "hl.dsp.focus({ direction = ${luaStr dir} })";
      desc = "focus ${dir}, crossing into Emacs splits";
    }
  ) dirs;

  moveKeys = lib.mapAttrs' (
    key: dir:
    lib.nameValuePair "move-${dir}" {
      inherit key;
      mods = "SUPER SHIFT";
      owner = "hyprland";
      dispatch = "hl.dsp.window.move({ direction = ${luaStr dir} })";
      desc = "move window ${dir}";
    }
  ) dirs;

  workspaceKeys = lib.listToAttrs (
    lib.concatMap (n: [
      {
        name = "workspace-${n}";
        value = {
          key = n;
          owner = "hyprland";
          dispatch = "hl.dsp.focus({ workspace = ${n} })";
          desc = "workspace ${n}";
          mark = true;
        };
      }
      {
        name = "send-${n}";
        value = {
          key = n;
          mods = "SUPER SHIFT";
          owner = "hyprland";
          dispatch = "hl.dsp.window.move({ workspace = ${n} })";
          desc = "send window to workspace ${n}";
        };
      }
    ]) (map toString (lib.range 1 9))
  );

  hyprKey = mods: key: dispatch: desc: {
    inherit
      mods
      key
      dispatch
      desc
      ;
    owner = "hyprland";
  };
  sub = hyprKey "";
  subShift = hyprKey "SHIFT";
  top = hyprKey "SUPER";
  escape = hyprKey "SUPER CTRL ALT";

  emacsKey = mods: key: elisp: desc: {
    inherit
      mods
      key
      elisp
      desc
      ;
    owner = "emacs";
  };
in
{
  imports = [
    ./wm-keys.nix
    ./wm-bridge.nix
  ];

  config = {
    programs.kitty.enable = true;

    local.wm.keys =
      focusKeys
      // moveKeys
      // workspaceKeys
      // {
        workspace-last = top "Tab" "hl.dsp.focus({ workspace = \"previous\" })" "last workspace" // {
          mark = true;
        };
        ace = {
          key = "o";
          owner = "bridge";
          elisp = "wm-ace";
          dispatch = "hl.dsp.window.cycle_next()";
          desc = "jump to any window or Emacs split";
          mark = true;
        };
        ace-swap = {
          key = "o";
          mods = "SUPER SHIFT";
          owner = "bridge";
          elisp = "wm-ace-swap";
          dispatch = "hl.dsp.window.swap({ direction = \"r\" })";
          desc = "swap with a chosen window";
        };
        switch-buffer = emacsKey "SUPER" "b" "wm-switch-buffer" "switch buffer, window or browser tab" // {
          mark = true;
        };
        kill-ring = emacsKey "SUPER" "y" "wm-kill-ring" "yank from the Emacs kill ring";
        mark-pop = emacsKey "SUPER" "comma" "wm-mark-pop" "pop the unified mark ring";
        mark-unpop = emacsKey "SUPER" "period" "wm-mark-unpop" "unpop the unified mark ring";
        eshell-here = {
          key = "Return";
          owner = "bridge";
          elisp = "wm-eshell-here";
          dispatch = "hl.dsp.exec_cmd(\"kitty\")";
          desc = "eshell at the focused window's cwd";
        };
        term-here = {
          key = "Return";
          mods = "SUPER SHIFT";
          owner = "bridge";
          elisp = "wm-term-here";
          dispatch = "hl.dsp.exec_cmd(\"kitty\")";
          desc = "terminal at the focused window's cwd";
        };
        close-window = top "q" "hl.dsp.window.close()" "close window";
        full-width = top "f" "hl.dsp.window.fullscreen(1)" "toggle full width";
        escape-emacs-restart =
          escape "r" "hl.dsp.exec_cmd(\"systemctl --user restart emacs.service\")"
            "restart the Emacs daemon";
        escape-terminal = escape "e" "hl.dsp.exec_cmd(\"kitty\")" "terminal not depending on Emacs";
        escape-panic = escape "p" "hl.dsp.exec_cmd(\"wm-panic\")" "make bridge keys dispatch directly";
      };

    local.wm.submaps = {
      window = {
        key = "w";
        desc = "window and column";
        keys = {
          win-left = sub "h" "hl.dsp.window.move({ direction = \"l\" })" "move left in the strip";
          win-right = sub "l" "hl.dsp.window.move({ direction = \"r\" })" "move right in the strip";
          win-up = sub "k" "hl.dsp.window.move({ direction = \"u\" })" "move up within the column";
          win-down = sub "j" "hl.dsp.window.move({ direction = \"d\" })" "move down within the column";
          win-wider = sub "equal" "hl.dsp.layout(\"colresize +conf\")" "next column width preset";
          win-narrower = sub "minus" "hl.dsp.layout(\"colresize -conf\")" "previous column width preset";
          win-fit = sub "f" "hl.dsp.layout(\"fit active\")" "fit the active column";
          win-fit-visible = sub "v" "hl.dsp.layout(\"fit visible\")" "fit all visible columns";
          win-promote = sub "p" "hl.dsp.layout(\"promote\")" "promote window to its own column";
          win-expel = sub "e" "hl.dsp.layout(\"expel\")" "expel window from the column";
          win-float = sub "t" "hl.dsp.window.float()" "toggle floating";
          win-close = sub "d" "hl.dsp.window.close()" "close window";
        };
      };

      session = {
        key = "s";
        desc = "session and system";
        keys = {
          ses-emacs-restart =
            sub "r" "hl.dsp.exec_cmd(\"systemctl --user restart emacs.service\")"
              "restart the Emacs daemon";
          ses-reload = subShift "r" "hl.dsp.exec_cmd(\"hyprctl reload\")" "reload Hyprland config";
          ses-suspend = sub "s" "hl.dsp.exec_cmd(\"systemctl suspend\")" "suspend";
          ses-exit = sub "q" "hl.dsp.exit()" "log out";
        };
      };

      monitor = {
        key = "m";
        desc = "monitor";
        keys = {
          mon-left = sub "h" "hl.dsp.focus({ monitor = \"l\" })" "focus monitor left";
          mon-right = sub "l" "hl.dsp.focus({ monitor = \"r\" })" "focus monitor right";
          mon-send-left =
            subShift "h" "hl.dsp.window.move({ monitor = \"l\" })"
              "send window to monitor left";
          mon-send-right =
            subShift "l" "hl.dsp.window.move({ monitor = \"r\" })"
              "send window to monitor right";
        };
      };

      project = {
        key = "p";
        desc = "project";
        keys = {
          prj-switch = emacsKey "" "p" "wm-project-switch" "switch project";
          prj-eshell = emacsKey "" "e" "wm-project-eshell" "eshell in project root";
          prj-dired = emacsKey "" "d" "wm-project-dired" "dired in project root";
          prj-magit = emacsKey "" "g" "wm-project-magit" "magit status";
        };
      };
    };

    wayland.windowManager.hyprland = {
      enable = true;
      configType = "lua";
      settings = { };
      extraConfig = ''
        ${settingsLua}
        dofile("${cfg.bindsFile}")
        pcall(dofile, "${config.local.theme.hyprLua}")
      '';
    };

    # KDE uses the NixOS portal set. Letting Home Manager generate its own
    # Hyprland-only portal directory hides xdg-desktop-portal-kde from KDE.
    xdg.portal.enable = lib.mkForce false;
  };
}

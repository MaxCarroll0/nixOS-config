# Hyprland session: Caelestia's look over the core scrolling layout, generated keybinds.

{
  config,
  lib,
  ...
}:

let
  cfg = config.local.wm;

  luaStr = s: "\"" + lib.escape [ "\\" "\"" ] s + "\"";
  luaVal =
    v:
    if lib.isBool v then
      (if v then "true" else "false")
    else if lib.isInt v || lib.isFloat v then
      toString v
    else
      luaStr (toString v);
  luaTable =
    attrs: "{ ${lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: "${k} = ${luaVal v}") attrs)} }";

  hyprSettings = {
    "general.layout" = "scrolling";
    "general.allow_tearing" = false;

    "scrolling.column_width" = 0.5;
    "scrolling.explicit_column_widths" = "0.333, 0.5, 0.667, 1.0";
    "scrolling.focus_fit_method" = 1;
    "scrolling.fullscreen_on_one_column" = true;
    "scrolling.follow_focus" = true;

    "input.kb_layout" = "gb";
    "input.kb_options" = "caps:escape";
    "input.follow_mouse" = 0;
  };

  settingsLua = ''
    hl.monitor({ output = "", scale = 1 })

    local home = os.getenv("HOME")
    local hypr = home .. "/.config/hypr"
    package.path = package.path .. ";" .. home .. "/.config/caelestia/?.lua"

    local function seed(src, dst)
        local existing = io.open(dst)
        if existing then
            existing:close()
            return
        end
        local input = io.open(src, "r")
        if not input then return end
        local out = io.open(dst, "w")
        if out then
            out:write(input:read("*a"))
            out:close()
        end
        input:close()
    end
    seed(hypr .. "/scheme/default.lua", hypr .. "/scheme/current.lua")

    local vars = require("variables")
    for k, v in pairs(${luaTable cfg.caelestia.vars}) do vars[k] = v end
    local userVarsOk, userVars = pcall(require, "hypr-vars")
    if userVarsOk and type(userVars) == "table" then
        for k, v in pairs(userVars) do vars[k] = v end
    end

    ${lib.concatMapStringsSep "\n" (m: "require(${luaStr "hyprland.${m}"})") cfg.caelestia.hyprModules}

    hl.config({
    ${lib.concatStringsSep ",\n" (
      lib.mapAttrsToList (k: v: "  [${luaStr k}] = ${luaVal v}") hyprSettings
    )}
    })

    hl.env("QT_QPA_PLATFORMTHEME", "gtk3")

    hl.on("hyprland.start", function()
        hl.exec_cmd("hyprctl setcursor " .. vars.cursorTheme .. " " .. vars.cursorSize)
    end)
  '';

  dirs = {
    h = "l";
    j = "d";
    k = "u";
    l = "r";
  };

  dirNames = {
    l = "left";
    d = "down";
    u = "up";
    r = "right";
  };

  focusKeys = lib.mapAttrs' (
    key: dir:
    lib.nameValuePair "focus-${dir}" {
      inherit key;
      owner = "bridge";
      elisp = "wm-focus-${dir}";
      dispatch = "hl.dsp.focus({ direction = ${luaStr dir} })";
      desc = "focus ${dirNames.${dir}}, crossing into Emacs splits";
    }
  ) dirs;

  moveKeys = lib.mapAttrs' (
    key: dir:
    lib.nameValuePair "move-${dir}" {
      inherit key;
      mods = "SUPER SHIFT";
      owner = "hyprland";
      dispatch = "hl.dsp.window.move({ direction = ${luaStr dir} })";
      desc = "move window ${dirNames.${dir}}";
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

  shell = name: "hl.dsp.global(${luaStr "caelestia:${name}"})";
  shellKey =
    mods: key: name: desc:
    hyprKey mods key (shell name) desc;
  lockedKey =
    mods: key: dispatch: desc:
    hyprKey mods key dispatch desc // { flags = [ "locked" ]; };

  wpctl = args: "hl.dsp.exec_cmd(${luaStr "wpctl ${args}"})";

  mediaKeys = {
    media-play = lockedKey "" "XF86AudioPlay" (shell "mediaToggle") "play or pause media";
    media-pause = lockedKey "" "XF86AudioPause" (shell "mediaToggle") "play or pause media";
    media-next = lockedKey "" "XF86AudioNext" (shell "mediaNext") "next track";
    media-prev = lockedKey "" "XF86AudioPrev" (shell "mediaPrev") "previous track";
    media-stop = lockedKey "" "XF86AudioStop" (shell "mediaStop") "stop media";
    volume-up =
      lockedKey "" "XF86AudioRaiseVolume"
        (wpctl "set-mute @DEFAULT_AUDIO_SINK@ 0; wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 10%+")
        "volume up"
      // {
        flags = [
          "locked"
          "repeating"
        ];
      };
    volume-down =
      lockedKey "" "XF86AudioLowerVolume"
        (wpctl "set-mute @DEFAULT_AUDIO_SINK@ 0; wpctl set-volume @DEFAULT_AUDIO_SINK@ 10%-")
        "volume down"
      // {
        flags = [
          "locked"
          "repeating"
        ];
      };
    volume-mute = lockedKey "" "XF86AudioMute" (wpctl "set-mute @DEFAULT_AUDIO_SINK@ toggle") "mute";
    mic-mute =
      lockedKey "" "XF86AudioMicMute" (wpctl "set-mute @DEFAULT_AUDIO_SOURCE@ toggle")
        "mute microphone";
    brightness-up = lockedKey "" "XF86MonBrightnessUp" (shell "brightnessUp") "brightness up";
    brightness-down = lockedKey "" "XF86MonBrightnessDown" (shell "brightnessDown") "brightness down";
    screenshot-output =
      lockedKey "" "Print" "hl.dsp.exec_cmd(\"caelestia screenshot\")"
        "screenshot output";
  };

  emacsKey = mods: key: elisp: desc: {
    inherit
      mods
      key
      elisp
      desc
      ;
    owner = "emacs";
  };

  typing = b: b // { insert = true; };
in
{
  imports = [
    ./wm-keys.nix
    ./wm-bridge.nix
    ./caelestia.nix
  ];

  config = {
    programs.kitty.enable = true;

    local.wm.keys =
      focusKeys
      // moveKeys
      // workspaceKeys
      // mediaKeys
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
          insert = true;
        };
        ace-swap = {
          key = "o";
          mods = "SUPER SHIFT";
          owner = "bridge";
          elisp = "wm-ace-swap";
          dispatch = "hl.dsp.window.swap({ direction = \"r\" })";
          desc = "swap with a chosen window";
          insert = true;
        };
        switch-buffer = emacsKey "SUPER" "b" "wm-switch-buffer" "switch buffer, window or browser tab" // {
          mark = true;
          insert = true;
        };
        kill-ring = typing (emacsKey "SUPER" "y" "wm-kill-ring" "yank from the Emacs kill ring");
        mark-pop = emacsKey "SUPER" "comma" "wm-mark-pop" "pop the unified mark ring";
        mark-unpop = emacsKey "SUPER" "period" "wm-mark-unpop" "unpop the unified mark ring";
        eshell-here = {
          key = "Return";
          owner = "bridge";
          elisp = "wm-eshell-here";
          dispatch = "hl.dsp.exec_cmd(\"kitty\")";
          desc = "eshell at the focused window's cwd";
          insert = true;
        };
        term-here = {
          key = "Return";
          mods = "SUPER SHIFT";
          owner = "bridge";
          elisp = "wm-term-here";
          dispatch = "hl.dsp.exec_cmd(\"kitty\")";
          desc = "terminal at the focused window's cwd";
          insert = true;
        };
        launcher = typing (shellKey "SUPER" "space" "launcher" "application launcher");
        keybinds = shellKey "SUPER" "slash" "keybinds" "keybind reference";
        dashboard = shellKey "SUPER" "d" "dashboard" "dashboard";
        sidebar = shellKey "SUPER" "n" "sidebar" "notifications and quick settings";
        session-menu = typing (shellKey "CTRL ALT" "Delete" "session" "session menu");
        clear-notifications = lockedKey "CTRL ALT" "c" (shell "clearNotifs") "clear notifications";
        close-window = top "q" "hl.dsp.window.close()" "close window";
        full-width = top "f" "hl.dsp.window.fullscreen(1)" "toggle full width";
        escape-emacs-restart =
          escape "r" "hl.dsp.exec_cmd(\"systemctl --user restart emacs.service\")"
            "restart the Emacs daemon";
        escape-terminal = typing (
          escape "e" "hl.dsp.exec_cmd(\"kitty\")" "terminal not depending on Emacs"
        );
        escape-panic =
          escape "p" "hl.dsp.exec_cmd(\"${cfg.panicCommand}\")"
            "make bridge keys dispatch directly";
      };

    local.wm.keypad = {
      kp-launcher = typing (hyprKey "" "space" (shell "launcher") "application launcher");
      kp-keybinds = hyprKey "" "slash" (shell "keybinds") "keybind reference";
      kp-dashboard = hyprKey "" "d" (shell "dashboard") "dashboard";
      kp-sidebar = hyprKey "" "n" (shell "sidebar") "notifications and quick settings";
      kp-session = typing (hyprKey "" "x" (shell "session") "session menu");
    };

    local.wm.submaps = {
      window = {
        key = "w";
        desc = "window and column";
        sticky = true;
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
          ses-lock = sub "l" (shell "lock") "lock";
          ses-emacs-restart =
            sub "r" "hl.dsp.exec_cmd(\"systemctl --user restart emacs.service\")"
              "restart the Emacs daemon";
          ses-shell-restart =
            sub "c" "hl.dsp.exec_cmd(\"systemctl --user restart caelestia.service\")"
              "restart the shell";
          ses-reload = subShift "r" "hl.dsp.exec_cmd(\"hyprctl reload\")" "reload Hyprland config";
          ses-suspend = sub "s" "hl.dsp.exec_cmd(\"systemctl suspend\")" "suspend";
          ses-exit = sub "q" "hl.dsp.exit()" "log out";
        };
      };

      grab = {
        key = "g";
        desc = "grab";
        keys = {
          grab-region = sub "r" (shell "screenshot") "screenshot region or window";
          grab-frozen = sub "f" (shell "screenshotFreeze") "screenshot region of a frozen screen";
          grab-output = sub "o" "hl.dsp.exec_cmd(\"caelestia screenshot\")" "screenshot output";
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
          prj-switch = typing (emacsKey "" "p" "wm-project-switch" "switch project");
          prj-eshell = typing (emacsKey "" "e" "wm-project-eshell" "eshell in project root");
          prj-dired = typing (emacsKey "" "d" "wm-project-dired" "dired in project root");
          prj-magit = typing (emacsKey "" "g" "wm-project-magit" "magit status");
        };
      };
    };

    wayland.windowManager.hyprland = {
      enable = true;
      package = null;
      portalPackage = null;
      configType = "lua";
      settings = { };
      extraConfig = ''
        ${settingsLua}
        dofile("${cfg.bindsFile}")
        pcall(require, "hypr-user")
      '';
    };

    # KDE uses the NixOS portal set. Letting Home Manager generate its own
    # Hyprland-only portal directory hides xdg-desktop-portal-kde from KDE.
    xdg.portal.enable = lib.mkForce false;
  };
}

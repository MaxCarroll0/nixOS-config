# Hyprland session: Caelestia's look over the core scrolling layout, generated keybinds.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.wm;

  suspendUnlessPlaying = pkgs.writeShellScript "suspend-unless-playing" ''
    ${pkgs.playerctl}/bin/playerctl --all-players status 2>/dev/null | grep -qx Playing || systemctl suspend
  '';

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
    "general.layout" = "lua:strip";
    "general.allow_tearing" = false;

    "scrolling.column_width" = 0.5;
    "scrolling.explicit_column_widths" = "0.333, 0.5, 0.667, 1.0";
    "scrolling.focus_fit_method" = 1;
    "scrolling.fullscreen_on_one_column" = false;
    "scrolling.follow_focus" = true;

    "input.kb_layout" = "gb";
    "input.kb_options" = "caps:none";
    "input.follow_mouse" = 0;
    "input.focus_on_close" = 0;
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
    hl.animation({ leaf = "workspaces", enabled = true, speed = 5, bezier = "standard", style = "slidevert" })

    package.path = hypr .. "/?.lua;" .. hypr .. "/?/init.lua;" .. package.path
    for name in pairs(package.loaded) do
        if name == "wm" or name:sub(1, 3) == "wm." then package.loaded[name] = nil end
    end
    require("wm")

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

  wmCall = call: "function() wm.${call} end";

  bridgeFocus = dir: {
    owner = "bridge";
    elisp = "wm-focus-${dir}";
    dispatch = "hl.dsp.focus({ direction = ${luaStr dir} })";
    desc = "focus ${dirNames.${dir}}, crossing into Emacs splits";
  };

  windowFocusKeys = lib.mapAttrs' (
    key: dir:
    lib.nameValuePair "win-focus-${dir}" (
      bridgeFocus dir
      // {
        inherit key;
        mods = "";
      }
    )
  ) dirs;

  windowMoveKeys = lib.mapAttrs' (
    key: dir:
    lib.nameValuePair "win-move-${dir}" {
      inherit key;
      mods = "SHIFT";
      owner = "hyprland";
      dispatch = wmCall "move(${luaStr dir})";
      desc = "move ${dirNames.${dir}}";
    }
  ) dirs;

  selectFocusKeys = lib.mapAttrs' (
    key: dir:
    lib.nameValuePair "sel-focus-${dir}" {
      inherit key;
      mods = "";
      owner = "hyprland";
      checkpoint = false;
      dispatch = wmCall "focus_within(${luaStr dir})";
      desc = "focus ${dirNames.${dir}} within the selection";
    }
  ) dirs;

  resizeKeys = {
    column-wider = top "equal" (wmCall "resize_column(\"+\")") "wider column";
    column-narrower = top "minus" (wmCall "resize_column(\"-\")") "narrower column, then scroll on";
    column-wider-fine = hyprKey "SUPER CTRL" "equal" (wmCall "resize_column(0.02)") "slightly wider";
    column-narrower-fine =
      hyprKey "SUPER CTRL" "minus" (wmCall "resize_column(-0.02)")
        "slightly narrower";
    row-taller = hyprKey "SUPER SHIFT" "equal" (wmCall "resize_row(0.1)") "taller row";
    row-shorter = hyprKey "SUPER SHIFT" "minus" (wmCall "resize_row(-0.1)") "shorter row";
    row-taller-fine =
      hyprKey "SUPER CTRL SHIFT" "equal" (wmCall "resize_row(0.02)")
        "slightly taller row";
    row-shorter-fine =
      hyprKey "SUPER CTRL SHIFT" "minus" (wmCall "resize_row(-0.02)")
        "slightly shorter row";
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
      dispatch = wmCall "move(${luaStr dir})";
      desc = "move window or selection ${dirNames.${dir}}";
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
    volume-up = lockedKey "" "XF86AudioRaiseVolume" (shell "volumeUp") "volume up" // {
      flags = [
        "locked"
        "repeating"
      ];
    };
    volume-down = lockedKey "" "XF86AudioLowerVolume" (shell "volumeDown") "volume down" // {
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

  grouped = group: lib.mapAttrs (_: b: b // { inherit group; });
in
{
  imports = [
    ./wm-keys.nix
    ./wm-bridge.nix
    ./caelestia.nix
  ];

  config = {
    programs.kitty.enable = true;

    xdg.configFile."hypr/wm".source = ./hypr/wm;

    local.wm.keys =
      grouped "focus" (
        focusKeys
        // lib.filterAttrs (name: _: lib.hasPrefix "workspace-" name) workspaceKeys
        // {
          workspace-last = top "grave" "hl.dsp.focus({ workspace = \"previous\" })" "last workspace" // {
            mark = true;
          };
          ace = top "o" (wmCall "ace(\"jump\")") "jump to any window or Emacs split" // {
            checkpoint = false;
            mark = true;
          };
          switch-buffer = emacsKey "SUPER" "b" "wm-switch-buffer" "switch buffer, window or browser tab" // {
            mark = true;
            insert = true;
          };
          mark-pop = top "bracketleft" (wmCall "mark_pop()") "pop the unified mark ring" // {
            checkpoint = false;
          };
          mark-unpop = top "bracketright" (wmCall "mark_unpop()") "unpop the unified mark ring" // {
            checkpoint = false;
          };
          align = top "z" (wmCall "align_left()") "scroll the focused column to the left edge" // {
            checkpoint = false;
          };
          pan-left = hyprKey "SUPER CTRL" "h" (wmCall "pan(-1)") "scroll the view left, free of columns" // {
            checkpoint = false;
          };
          pan-right = hyprKey "SUPER CTRL" "l" (wmCall "pan(1)") "scroll the view right, free of columns" // {
            checkpoint = false;
          };
        }
      )
      // grouped "move" (moveKeys // lib.filterAttrs (name: _: lib.hasPrefix "send-" name) workspaceKeys)
      // grouped "size" (
        resizeKeys
        // {
          fill = top "f" (wmCall "fill()") "fill, again to restore";
          fullscreen =
            hyprKey "SUPER SHIFT" "f" "hl.dsp.window.fullscreen({ mode = \"fullscreen\" })"
              "toggle fullscreen";
        }
      )
      // grouped "media" mediaKeys
      // grouped "edit" {
        cut = top "s" (wmCall "cut()") "cut to the edge, remembered for paste";
        paste = top "p" (wmCall "paste()") "paste below the focused window";
        replace = top "r" (wmCall "replace()") "paste over the focused window";
        evict = top "q" (wmCall "evict()") "evict to the nearer edge";
        rotate = top "t" (wmCall "rotate(true)") "rotate clockwise";
        rotate-back = hyprKey "SUPER SHIFT" "t" (wmCall "rotate(false)") "rotate anticlockwise";
        undo = top "u" (wmCall "undo()") "undo" // {
          checkpoint = false;
        };
      }
      // grouped "select" {
        select-row = top "x" (wmCall "select_row()") "select the row";
        select-column = hyprKey "SUPER SHIFT" "x" (wmCall "select_column()") "select the column";
        select-toggle = top "Tab" (wmCall "toggle_select()") "add or remove from the selection";
        select-mode = hyprKey "SUPER SHIFT" "Tab" (wmCall "select_mode()") "SELECT state";
        ace-select = hyprKey "SUPER SHIFT" "o" (wmCall "ace(\"select\")") "select any window by label" // {
          checkpoint = false;
        };
      }
      // grouped "launch" {
        kill-ring = typing (emacsKey "SUPER" "y" "wm-kill-ring" "yank from the Emacs kill ring");
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
      }
      // grouped "shell" {
        keybinds = shellKey "SUPER" "slash" "keybinds" "keybind reference";
        dashboard = shellKey "SUPER" "d" "dashboard" "dashboard";
        sidebar = shellKey "SUPER" "n" "sidebar" "notifications and quick settings";
        clear-notifications = lockedKey "CTRL ALT" "c" (shell "clearNotifs") "clear notifications";
      }
      // grouped "session" {
        session-menu = typing (shellKey "CTRL ALT" "Delete" "session" "session menu");
      }
      // grouped "escape" {
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

    local.wm.keypad =
      grouped "launch" {
        kp-launcher = typing (hyprKey "" "space" (shell "launcher") "application launcher");
      }
      // grouped "shell" {
        kp-keybinds = hyprKey "" "slash" (shell "keybinds") "keybind reference";
        kp-dashboard = hyprKey "" "d" (shell "dashboard") "dashboard";
        kp-sidebar = hyprKey "" "n" (shell "sidebar") "notifications and quick settings";
      }
      // grouped "edit" {
        kp-close = sub "c" (wmCall "close()") "close window or selection" // {
          prefix = [ "x" ];
        };
      };

    local.wm.select = selectFocusKeys;

    local.wm.submaps = {
      window = {
        key = "w";
        desc = "window and column";
        keys =
          grouped "focus" windowFocusKeys
          // grouped "move" windowMoveKeys
          // grouped "size" {
            win-column-wider = sub "equal" (wmCall "resize_column(\"+\")") "wider column";
            win-column-narrower = sub "minus" (wmCall "resize_column(\"-\")") "narrower column";
            win-fit = sub "a" "hl.dsp.layout(\"fit active\")" "fit the active column";
            win-fit-visible = sub "v" "hl.dsp.layout(\"fit visible\")" "fit all visible columns";
            win-fill = sub "f" (wmCall "fill()") "fill, again to restore";
            win-fill-row = sub "r" (wmCall "fill_row()") "fill row, again to restore";
            win-fill-column = sub "c" (wmCall "fill_column()") "fill column, again to restore";
          }
          // grouped "edit" {
            win-float = sub "t" "hl.dsp.window.float()" "toggle floating";
            win-close = sub "d" (wmCall "close()") "close window or selection";
          };
      };

      session = {
        key = "s";
        desc = "session and system";
        keypadOnly = true;
        keys = grouped "session" {
          ses-menu = typing (sub "x" (shell "session") "session menu");
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
        keys = grouped "shell" {
          grab-screenshot-region = sub "r" (shell "screenshot") "screenshot region or window";
          grab-screenshot-frozen = sub "f" (shell "screenshotFreeze") "screenshot region of a frozen screen";
          grab-screenshot-output = sub "o" "hl.dsp.exec_cmd(\"caelestia screenshot\")" "screenshot output";
        };
      };

      monitor = {
        key = "m";
        desc = "monitor";
        keys =
          grouped "focus" {
            mon-monitor-l = sub "h" "hl.dsp.focus({ monitor = \"l\" })" "focus monitor left";
            mon-monitor-r = sub "l" "hl.dsp.focus({ monitor = \"r\" })" "focus monitor right";
          }
          // grouped "move" {
            mon-send-monitor-l =
              subShift "h" "hl.dsp.window.move({ monitor = \"l\" })"
                "send window to monitor left";
            mon-send-monitor-r =
              subShift "l" "hl.dsp.window.move({ monitor = \"r\" })"
                "send window to monitor right";
          };
      };

      project = {
        key = "period";
        desc = "project";
        keys =
          grouped "focus" {
            prj-project-switch = typing (emacsKey "" "p" "wm-project-switch" "switch project") // {
              mark = true;
            };
          }
          // grouped "launch" {
            prj-project-eshell = typing (emacsKey "" "e" "wm-project-eshell" "eshell in project root");
            prj-project-dired = typing (emacsKey "" "d" "wm-project-dired" "dired in project root");
            prj-project-magit = typing (emacsKey "" "g" "wm-project-magit" "magit status");
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
        hl.bind("switch:on:Lid Switch", function()
          hl.dispatch(${shell "lock"})
          hl.dispatch(hl.dsp.dpms({ action = "disable", monitor = "eDP-1" }))
          hl.dispatch(hl.dsp.exec_cmd("${suspendUnlessPlaying}"))
        end, { locked = true, description = "lid closed: lock, panel off, suspend unless playing" })
        hl.bind("switch:off:Lid Switch", hl.dsp.dpms({ action = "enable", monitor = "eDP-1" }), { locked = true, description = "lid opened: panel on" })
        pcall(require, "hypr-user")
      '';
    };

    # KDE uses the NixOS portal set. Letting Home Manager generate its own
    # Hyprland-only portal directory hides xdg-desktop-portal-kde from KDE.
    xdg.portal.enable = lib.mkForce false;
  };
}

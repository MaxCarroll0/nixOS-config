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

  emacsClass = "^(emacs|Emacs)$";

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
      dispatch = "movefocus, ${dir}";
      desc = "focus ${dir}, crossing into Emacs splits";
    }
  ) dirs;

  moveKeys = lib.mapAttrs' (
    key: dir:
    lib.nameValuePair "move-${dir}" {
      inherit key;
      mods = "SUPER SHIFT";
      owner = "hyprland";
      dispatch = "movewindow, ${dir}";
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
          dispatch = "workspace, ${n}";
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
          dispatch = "movetoworkspace, ${n}";
          desc = "send window to workspace ${n}";
        };
      }
    ]) (map toString (lib.range 1 9))
  );
in
{
  imports = [ ./wm-keys.nix ];

  config = {
    programs.kitty.enable = true;

    local.wm.keys =
      focusKeys
      // moveKeys
      // workspaceKeys
      // {
        workspace-last = {
          key = "Tab";
          owner = "hyprland";
          dispatch = "workspace, previous";
          desc = "last workspace";
          mark = true;
        };
        ace = {
          key = "o";
          owner = "bridge";
          elisp = "wm-ace";
          dispatch = "cyclenext";
          desc = "jump to any window or Emacs split";
          mark = true;
        };
        ace-swap = {
          key = "o";
          mods = "SUPER SHIFT";
          owner = "bridge";
          elisp = "wm-ace-swap";
          dispatch = "swapnext";
          desc = "swap with a chosen window";
        };
        switch-buffer = {
          key = "b";
          owner = "emacs";
          elisp = "wm-switch-buffer";
          desc = "switch buffer, window or browser tab";
          mark = true;
        };
        kill-ring = {
          key = "y";
          owner = "emacs";
          elisp = "wm-kill-ring";
          desc = "yank from the Emacs kill ring";
        };
        mark-pop = {
          key = "comma";
          owner = "emacs";
          elisp = "wm-mark-pop";
          desc = "pop the unified mark ring";
        };
        mark-unpop = {
          key = "period";
          owner = "emacs";
          elisp = "wm-mark-unpop";
          desc = "unpop the unified mark ring";
        };
        eshell-here = {
          key = "Return";
          owner = "bridge";
          elisp = "wm-eshell-here";
          dispatch = "exec, kitty";
          desc = "eshell at the focused window's cwd";
        };
        term-here = {
          key = "Return";
          mods = "SUPER SHIFT";
          owner = "bridge";
          elisp = "wm-term-here";
          dispatch = "exec, kitty";
          desc = "terminal at the focused window's cwd";
        };
        close-window = {
          key = "q";
          owner = "hyprland";
          dispatch = "killactive";
          desc = "close window";
        };
        full-width = {
          key = "f";
          owner = "hyprland";
          dispatch = "fullscreen, 1";
          desc = "toggle full width";
        };
        escape-emacs-restart = {
          key = "r";
          mods = "SUPER CTRL ALT";
          owner = "hyprland";
          dispatch = "exec, systemctl --user restart emacs.service";
          desc = "restart the Emacs daemon";
        };
        escape-terminal = {
          key = "e";
          mods = "SUPER CTRL ALT";
          owner = "hyprland";
          dispatch = "exec, kitty";
          desc = "terminal not depending on Emacs";
        };
        escape-panic = {
          key = "p";
          mods = "SUPER CTRL ALT";
          owner = "hyprland";
          dispatch = "exec, wm-panic";
          desc = "rebind every bridge key to its Hyprland fallback";
        };
      };

    local.wm.submaps = {
      window = {
        key = "w";
        desc = "window and column";
        keys = {
          win-left = {
            mods = "";
            key = "h";
            owner = "hyprland";
            dispatch = "movewindow, l";
            desc = "move left in the strip";
          };
          win-right = {
            mods = "";
            key = "l";
            owner = "hyprland";
            dispatch = "movewindow, r";
            desc = "move right in the strip";
          };
          win-up = {
            mods = "";
            key = "k";
            owner = "hyprland";
            dispatch = "movewindow, u";
            desc = "move up within the column";
          };
          win-down = {
            mods = "";
            key = "j";
            owner = "hyprland";
            dispatch = "movewindow, d";
            desc = "move down within the column";
          };
          win-wider = {
            mods = "";
            key = "equal";
            owner = "hyprland";
            dispatch = "layoutmsg, colresize +conf";
            desc = "next column width preset";
          };
          win-narrower = {
            mods = "";
            key = "minus";
            owner = "hyprland";
            dispatch = "layoutmsg, colresize -conf";
            desc = "previous column width preset";
          };
          win-fit = {
            mods = "";
            key = "f";
            owner = "hyprland";
            dispatch = "layoutmsg, fit active";
            desc = "fit the active column";
          };
          win-fit-visible = {
            mods = "";
            key = "v";
            owner = "hyprland";
            dispatch = "layoutmsg, fit visible";
            desc = "fit all visible columns";
          };
          win-promote = {
            mods = "";
            key = "p";
            owner = "hyprland";
            dispatch = "layoutmsg, promote";
            desc = "promote window to its own column";
          };
          win-expel = {
            mods = "";
            key = "e";
            owner = "hyprland";
            dispatch = "layoutmsg, expel";
            desc = "expel window from the column";
          };
          win-float = {
            mods = "";
            key = "t";
            owner = "hyprland";
            dispatch = "togglefloating";
            desc = "toggle floating";
          };
          win-close = {
            mods = "";
            key = "d";
            owner = "hyprland";
            dispatch = "killactive";
            desc = "close window";
          };
        };
      };

      session = {
        key = "s";
        desc = "session and system";
        keys = {
          ses-emacs-restart = {
            mods = "";
            key = "r";
            owner = "hyprland";
            dispatch = "exec, systemctl --user restart emacs.service";
            desc = "restart the Emacs daemon";
          };
          ses-reload = {
            mods = "SHIFT";
            key = "r";
            owner = "hyprland";
            dispatch = "exec, hyprctl reload";
            desc = "reload Hyprland config";
          };
          ses-suspend = {
            mods = "";
            key = "s";
            owner = "hyprland";
            dispatch = "exec, systemctl suspend";
            desc = "suspend";
          };
          ses-exit = {
            mods = "";
            key = "q";
            owner = "hyprland";
            dispatch = "exit";
            desc = "log out";
          };
        };
      };

      monitor = {
        key = "m";
        desc = "monitor";
        keys = {
          mon-left = {
            mods = "";
            key = "h";
            owner = "hyprland";
            dispatch = "focusmonitor, l";
            desc = "focus monitor left";
          };
          mon-right = {
            mods = "";
            key = "l";
            owner = "hyprland";
            dispatch = "focusmonitor, r";
            desc = "focus monitor right";
          };
          mon-send-left = {
            mods = "SHIFT";
            key = "h";
            owner = "hyprland";
            dispatch = "movewindow, mon:l";
            desc = "send window to monitor left";
          };
          mon-send-right = {
            mods = "SHIFT";
            key = "l";
            owner = "hyprland";
            dispatch = "movewindow, mon:r";
            desc = "send window to monitor right";
          };
        };
      };

      project = {
        key = "p";
        desc = "project";
        keys = {
          prj-switch = {
            mods = "";
            key = "p";
            owner = "emacs";
            elisp = "wm-project-switch";
            desc = "switch project";
          };
          prj-eshell = {
            mods = "";
            key = "e";
            owner = "emacs";
            elisp = "wm-project-eshell";
            desc = "eshell in project root";
          };
          prj-dired = {
            mods = "";
            key = "d";
            owner = "emacs";
            elisp = "wm-project-dired";
            desc = "dired in project root";
          };
          prj-magit = {
            mods = "";
            key = "g";
            owner = "emacs";
            elisp = "wm-project-magit";
            desc = "magit status";
          };
        };
      };
    };

    wayland.windowManager.hyprland = {
      enable = true;
      configType = "hyprlang";

      settings = {
        monitor = ",preferred,auto,1";

        general = {
          gaps_in = 0;
          gaps_out = 40;
          border_size = 3;
          "col.active_border" = rgb c."border-active";
          "col.inactive_border" = rgb c."border-inactive";
          layout = "scrolling";
          allow_tearing = false;
        };

        scrolling = {
          column_width = 0.5;
          explicit_column_widths = "0.333, 0.5, 0.667, 1.0";
          focus_fit_method = 1;
          fullscreen_on_one_column = true;
          follow_focus = true;
        };

        decoration = {
          rounding = 7;
          inactive_opacity = 0.99;
          blur = {
            enabled = true;
            size = 1;
            passes = 2;
            vibrancy = 0.1696;
          };
          shadow = {
            enabled = light;
            range = 7;
            render_power = 9;
            offset = "5 4";
            color = rgba "aa" c."fg-faint";
          };
        };

        animations = {
          enabled = true;
          bezier = [
            "easeOutQuint, 0.23, 1, 0.32, 1"
            "almostLinear, 0.5, 0.5, 0.75, 1.0"
            "quick, 0.15, 0, 0.1, 1"
            "fakeElastic, 0.68, -0.1, 0.265, 1"
            "xfcBezier, 0.1, 0.9, 0.1, 1.03"
          ];
          animation = [
            "windows, 1, 4.79, easeOutQuint"
            "windowsIn, 1, 4, default, slide bottom"
            "windowsOut, 1, 8, default, slide top"
            "windowsMove, 1, 3, fakeElastic, slide"
            "border, 1, 1.39, easeOutQuint"
            "fade, 1, 3.03, quick"
            "layers, 1, 3.81, easeOutQuint"
            "layersIn, 1, 4, easeOutQuint, fade"
            "layersOut, 1, 1.5, linear, fade"
            "workspaces, 1, 4, xfcBezier"
          ];
        };

        input = {
          kb_layout = "gb";
          kb_options = "caps:escape";
          follow_mouse = 0;
        };

        misc = {
          disable_hyprland_logo = true;
          force_default_wallpaper = 0;
          vfr = true;
          vrr = 0;
        };

        windowrule = [
          "bordersize 0, class:${emacsClass}"
          "rounding 0, class:${emacsClass}"
          "noshadow, class:${emacsClass}"
        ];
      };

      extraConfig = "source = ${cfg.bindsConf}";
    };

    # KDE uses the NixOS portal set. Letting Home Manager generate its own
    # Hyprland-only portal directory hides xdg-desktop-portal-kde from KDE.
    xdg.portal.enable = lib.mkForce false;
  };
}

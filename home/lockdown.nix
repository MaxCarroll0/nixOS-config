# Scheduled Hyprland lockdown profiles: an allowlist of windows until a goal is met or a password is entered for the day.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.lockdown;

  lockdown = pkgs.writers.writePython3Bin "lockdown" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../pkgs/lockdown/lockdown.py);

  luaStr = s: "\"" + lib.escape [ "\\" "\"" ] s + "\"";

  ruleType = lib.types.submodule {
    options = {
      class = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Lua pattern matched against the window class; null matches nothing on its own.";
      };
      title = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Lua pattern matched against the window title; null matches nothing on its own.";
      };
    };
  };

  bindType = lib.types.submodule {
    options = {
      key = lib.mkOption {
        type = lib.types.str;
        description = "Hyprland key spec such as SUPER+p.";
      };
      command = lib.mkOption {
        type = lib.types.str;
        description = "Shell command run when the key is pressed during lockdown.";
      };
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Text shown in the keybind reference.";
      };
    };
  };

  actionType = lib.types.submodule {
    options = {
      label = lib.mkOption {
        type = lib.types.str;
        description = "Button text on the lock banner.";
      };
      command = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Command run detached when the button is pressed.";
      };
    };
  };

  profileType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether the profile is evaluated at all; a disabled profile never engages.";
        };
        workspace = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Named workspace the lockdown pins focus to; allowlisted windows live there.";
        };
        actions = lib.mkOption {
          type = lib.types.listOf actionType;
          default = [ ];
          description = "Buttons shown on the lock banner while the profile is engaged.";
        };
        days = lib.mkOption {
          type = lib.types.listOf (lib.types.ints.between 1 7);
          default = [
            1
            2
            3
            4
            5
          ];
          description = "ISO weekdays the profile engages on; the default is Monday to Friday.";
        };
        start = lib.mkOption {
          type = lib.types.str;
          description = "Local HH:MM from which the profile engages.";
        };
        from = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "ISO date of the first day the profile engages; null engages from now on.";
        };
        end = lib.mkOption {
          type = lib.types.str;
          default = "24:00";
          description = "Local HH:MM at which the profile stops engaging; the default is midnight.";
        };
        password = lib.mkOption {
          type = lib.types.str;
          description = "Plaintext password that releases the profile until midnight.";
        };
        releaseCheck = lib.mkOption {
          type = lib.types.nullOr (lib.types.listOf lib.types.str);
          default = null;
          description = "Command whose exit status 0 releases the profile for the rest of the day; null never releases.";
        };
        allow = lib.mkOption {
          type = lib.types.attrsOf (lib.types.listOf ruleType);
          description = "Windows kept visible per substate; the profile starts each day in substate active.";
        };
        binds = lib.mkOption {
          type = lib.types.listOf bindType;
          default = [ ];
          description = "Global keys for this profile, such as pausing the clock while engaged.";
        };
        onEngage = lib.mkOption {
          type = lib.types.nullOr (lib.types.listOf lib.types.str);
          default = null;
          description = "Command run when the profile engages.";
        };
        onRelease = lib.mkOption {
          type = lib.types.nullOr (lib.types.listOf lib.types.str);
          default = null;
          description = "Command run when the profile releases.";
        };
        message = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Text shown on the unlock prompt.";
        };
        settingsFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "JSON file signed with the password whose days, start, from and lockdown switch override the profile's own.";
        };
      };
    }
  );

  stripRule = r: lib.filterAttrs (_: v: v != null) r;

  promptClass = "lockdown-prompt";

  enabled = lib.filterAttrs (_: p: p.enable) cfg.profiles;

  profilesJson = lib.mapAttrs (_: p: {
    inherit (p)
      workspace
      actions
      days
      start
      from
      end
      password
      message
      ;
    release_check = p.releaseCheck;
    on_engage = p.onEngage;
    on_release = p.onRelease;
    settings_file = p.settingsFile;
    allow = lib.mapAttrs (_: map stripRule) p.allow;
    allow_always = [ { class = "^${promptClass}$"; } ];
  }) enabled;

  allBinds = lib.concatLists (lib.mapAttrsToList (_: p: p.binds) enabled);

  exec = cmd: "hl.dsp.exec_cmd(${luaStr cmd})";

  submapLua = ''
    ${lib.concatMapStringsSep "\n" (
      b: "hl.bind(${luaStr b.key}, ${exec b.command}, { description = ${luaStr b.description} })"
    ) allBinds}
    hl.bind("SUPER+F1", ${exec "kitty --class ${promptClass} -e ${lib.getExe lockdown} prompt"}, { description = "unlock with password" })
    hl.window_rule({ match = { class = "^${promptClass}$" }, float = true, center = true, pin = true, stay_focused = true, size = "640 220" })
    dofile("${config.xdg.configHome}/hypr/lockdown.lua")
  '';

  calendar =
    p:
    let
      days = lib.concatMapStringsSep "," (
        d:
        builtins.elemAt [
          "Mon"
          "Tue"
          "Wed"
          "Thu"
          "Fri"
          "Sat"
          "Sun"
        ] (d - 1)
      ) p.days;
    in
    "${days} ${p.start}";
in
{
  options.services.lockdown = {
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = lockdown;
      description = "The lockdown CLI.";
    };
    profiles = lib.mkOption {
      type = lib.types.attrsOf profileType;
      default = { };
      description = "Lockdown profiles by name; at most one is enforced at a time, the first by name.";
    };
  };

  config = lib.mkIf (enabled != { }) {
    home.packages = [
      lockdown
      pkgs.brightnessctl
    ];

    xdg.configFile."lockdown/profiles.json".text = builtins.toJSON profilesJson;
    xdg.configFile."hypr/lockdown.lua".source = ./hypr/lockdown.lua;

    wayland.windowManager.hyprland.extraConfig = lib.mkAfter submapLua;

    systemd.user.services.lockdown = {
      Unit = {
        Description = "Evaluate lockdown profiles";
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe lockdown} check";
        TimeoutStartSec = "60s";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.timers.lockdown = {
      Unit.Description = "Evaluate lockdown profiles at each start and every minute";
      Timer = {
        OnCalendar = [
          "minutely"
        ]
        ++ lib.mapAttrsToList (_: calendar) (lib.filterAttrs (_: p: p.days != [ ]) enabled);
        Persistent = true;
        AccuracySec = "5s";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}

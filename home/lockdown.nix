# Scheduled Hyprland lockdown profiles: an allowlist of windows and a submap per substate until a goal is met or a password is entered for the day.

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
      substates = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Substates whose submap holds this key; empty holds it in every substate.";
      };
      global = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the key is also bound outside the lockdown submaps.";
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
          description = "Keys held in the profile's submaps while engaged.";
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

  promptRule = {
    class = "^lockdown%-prompt$";
  };

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
    allow_always = [ promptRule ];
  }) enabled;

  exec = cmd: "hl.dsp.exec_cmd(${luaStr cmd})";

  entry = key: lua: description: { inherit key lua description; };

  heldIn = s: b: b.substates == [ ] || lib.elem s b.substates;

  submapOf = name: s: if s == "active" then name else "${name}-${s}";

  promptEntry =
    entry "SUPER+F1" (exec "kitty --class ${promptClass} -e ${lib.getExe lockdown} prompt")
      "unlock with password";

  baseEntries = [
    promptEntry
    (entry "ALT+Tab" "hl.dsp.window.cycle_next()" "next allowed window")
    (entry "SUPER+Tab" "hl.dsp.window.cycle_next()" "next allowed window, as ALT+Tab")
  ];

  entriesFor =
    p: s:
    map (b: entry b.key (exec b.command) b.description) (lib.filter (heldIn s) p.binds) ++ baseEntries;

  submaps = lib.concatLists (
    lib.mapAttrsToList (
      name: p:
      map (s: {
        inherit name s;
        submap = submapOf name s;
        entries = entriesFor p s;
      }) (lib.attrNames p.allow)
    ) enabled
  );

  globalEntries =
    lib.concatLists (
      lib.mapAttrsToList (
        _: p: map (b: entry b.key (exec b.command) b.description) (lib.filter (b: b.global) p.binds)
      ) enabled
    )
    ++ [ promptEntry ];

  bindLua = e: "hl.bind(${luaStr e.key}, ${e.lua}, { description = ${luaStr e.description} })";

  lockedLua = config.local.wm.lockedBindsLua or "";

  submapBlock = name: entries: ''
    hl.define_submap(${luaStr name}, function()
    ${lib.concatMapStringsSep "\n" bindLua entries}
    ${lockedLua}
    end)
  '';

  luaRule =
    r:
    "{ ${lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: "${k} = ${luaStr v}") (stripRule r))} }";
  luaRules = rs: "{ ${lib.concatMapStringsSep ", " luaRule rs} }";

  submapLua = ''
    ${lib.concatMapStringsSep "\n" bindLua globalEntries}
    hl.window_rule({ match = { class = "^${promptClass}$" }, float = true, center = true, pin = true, stay_focused = true, size = "640 220" })
    ${submapBlock "lockdown" baseEntries}
    ${lib.concatMapStringsSep "\n" (m: submapBlock m.submap m.entries) submaps}
    wm_app_submaps = wm_app_submaps or {}
    ${lib.concatMapStringsSep "\n" (n: "wm_app_submaps[${luaStr n}] = true") (
      [ "lockdown" ] ++ map (m: m.submap) submaps
    )}
    local lockdown = dofile("${config.xdg.configHome}/hypr/lockdown.lua")
    lockdown.submaps = { ${
      lib.concatStringsSep ", " (
        lib.mapAttrsToList (
          name: p:
          "[${luaStr name}] = { ${
            lib.concatMapStringsSep ", " (s: "[${luaStr s}] = ${luaStr (submapOf name s)}") (
              lib.attrNames p.allow
            )
          } }"
        ) enabled
      )
    } }
    lockdown.keep = { ${
      lib.concatStringsSep ", " (
        lib.mapAttrsToList (
          name: p:
          "[${luaStr name}] = ${luaRules (lib.concatLists (lib.attrValues p.allow) ++ [ promptRule ])}"
        ) enabled
      )
    } }
    lockdown.spare = ${luaRules cfg.spare}
  '';

  keyParts = spec: lib.splitString "+" spec;

  helpEntries =
    lib.mapAttrsToList
      (
        _: group:
        let
          e = (lib.head group).e;
          parts = keyParts e.key;
        in
        {
          mods = lib.concatStringsSep " " (lib.init parts);
          key = lib.last parts;
          desc = "${e.description} (${lib.concatMapStringsSep ", " (g: g.submap) group})";
          group = "lockdown";
          owner = "hyprland";
        }
      )
      (
        lib.groupBy (x: "${x.e.key}|${x.e.description}") (
          lib.concatMap (
            m:
            map (e: {
              inherit e;
              inherit (m) submap;
            }) m.entries
          ) submaps
        )
      );

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
    spare = lib.mkOption {
      type = lib.types.listOf ruleType;
      default = [
        { class = "[Cc]hrom"; }
        { class = "[Ff]irefox"; }
      ];
      description = "Windows whose process is never killed as a stray during a lockdown.";
    };
  };

  config = lib.mkIf (enabled != { }) {
    home.packages = [
      lockdown
      pkgs.brightnessctl
    ];

    xdg.configFile."lockdown/profiles.json".text = builtins.toJSON profilesJson;
    xdg.configFile."hypr/lockdown.lua".source = ./hypr/lockdown.lua;
    local.wm.lockdownHelp = helpEntries;

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

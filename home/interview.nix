# Weekday interview practice: the interview clock daemon, its hooks, and the lockdown profile that enforces it.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  repo = "${config.home.homeDirectory}/Jobs/general";
  firstDay = "2026-11-23";

  interview = pkgs.writers.writePython3Bin "interview" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../pkgs/interview/interview.py);

  emacs = config.programs.emacs.finalPackage;
  tutorEmacsState = "${config.xdg.stateHome}/interview-tutor-emacs";

  script =
    inputs: name:
    pkgs.writeShellApplication {
      name = "interview-${name}";
      runtimeInputs = [
        config.services.lockdown.package
        interview
        emacs
        pkgs.coreutils
        pkgs.jq
        pkgs.libnotify
        pkgs.util-linux
      ]
      ++ inputs;
      runtimeEnv = {
        INTERVIEW_REPO = repo;
        INTERVIEW_WORKSPACE = "interview";
        INTERVIEW_EL = "${../pkgs/interview/interview.el}";
        TUTOR_SCRATCH = "${tutorEmacsState}/scratch";
      };
      text = builtins.readFile ../pkgs/interview/${name}.sh;
    };

  emacsFrame = script [ ] "emacs-frame";
  tutorEmacsFrame = script [ ] "tutor-emacs-frame";
  onTutor = script [ tutorEmacsFrame ] "on-tutor";
  hookInputs = [
    emacsFrame
    tutorEmacsFrame
    onTutor
  ];

  hook = name: lib.getExe (script hookInputs name);

  tutorEmacsEnv = script [ ] "tutor-emacs-env";

  tutorEmacsRun = pkgs.writeShellScript "interview-tutor-emacs" (
    builtins.readFile ../pkgs/interview/tutor-emacs.sh
  );

  planWeek = pkgs.writeShellApplication {
    name = "interview-plan-week";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
      interview
    ];
    runtimeEnv = {
      INTERVIEW_REPO = repo;
      PLAN_ACCOUNT = "mjvcarroll@gmail.com";
    };
    text = builtins.readFile ../pkgs/interview/plan-week.sh;
  };

  lockdown = lib.getExe config.services.lockdown.package;
  interviewExe = lib.getExe interview;
in
{
  imports = [ ./lockdown.nix ];

  home.packages = [ interview ];

  local.wm.caelestia.patches = [ ./patches/caelestia-practice.patch ];

  home.activation.caelestiaPracticeEntry = lib.hm.dag.entryAfter [ "caelestiaVpnIcon" ] ''
    f="${config.xdg.configHome}/caelestia/shell.json"
    ${lib.getExe pkgs.jq} '
      .bar.entries = ((.bar.entries // [
        {id: "logo", enabled: true},
        {id: "workspaces", enabled: true},
        {id: "spacer", enabled: true},
        {id: "activeWindow", enabled: true},
        {id: "spacer", enabled: true},
        {id: "tray", enabled: true},
        {id: "clock", enabled: true},
        {id: "statusIcons", enabled: true},
        {id: "power", enabled: true}
      ]) | if any(.id == "practice") then . else map(if .id == "clock" then {id: "practice", enabled: true}, . else . end) end)
    ' "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
  '';

  xdg.configFile."interview/config.json".text = builtins.toJSON {
    inherit repo;
    coding_minutes = 45;
    review_minutes = 15;
    required_per_day = 2;
    lockdown = true;
    context = "LeetCode-style: well-known algorithm and data-structure classics, climbing the curriculum topic ladder from arrays and hashing to dynamic programming.";
    tracks = [
      {
        name = "ocaml";
        langs = [ "ocaml" ];
        difficulty = "easy-medium";
        context = "Functional style: immutable data (lists, Map, Set, folds, recursion). At most a quarter of OCaml problems may need mutation.";
      }
      {
        name = "systems";
        langs = [
          "rust"
          "c"
        ];
        difficulty = "easy";
        context = "Beginner in Rust and C: keep problems small and teach the language as it comes up, with beginner notes on ownership and borrowing in Rust and on pointers, lengths and memory in C.";
      }
      {
        name = "managed";
        langs = [
          "csharp"
          "python"
        ];
        difficulty = "easy-medium";
        context = "Idiomatic standard library use: LINQ and collections in C#, built-ins and comprehensions in Python.";
      }
    ];
    on_pause = [ (hook "on-pause") ];
    on_resume = [ (hook "on-resume") ];
    on_complete = [
      lockdown
      "check"
    ];
    on_start = [ (hook "on-start") ];
    auto = {
      enabled = true;
      days = [
        "Mon"
        "Tue"
        "Thu"
        "Fri"
      ];
      start = "05:00";
      break_minutes = 5;
      snooze_minutes = 15;
      from = firstDay;
      notify = lib.getExe' pkgs.libnotify "notify-send";
      inherit lockdown;
      lockdown_profile = "interview";
    };
  };

  systemd.user.services.interviewd = {
    Unit = {
      Description = "Interview clock";
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${interviewExe} daemon";
      Restart = "always";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.interview-plan-week = {
    Unit = {
      Description = "Plan next week's interview problems with Claude";
      After = [ "network-online.target" ];
      StartLimitIntervalSec = 0;
    };
    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe planWeek;
      Environment = [ "PATH=${config.home.profileDirectory}/bin:/run/current-system/sw/bin" ];
      Restart = "on-failure";
      RestartSec = "30min";
      TimeoutStartSec = "2h";
    };
  };

  systemd.user.timers.interview-plan-week = {
    Unit.Description = "Plan next week's interviews when the weekly usage limit resets (Saturday 16:59)";
    Timer = {
      OnCalendar = "Sat 17:05";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  services.lockdown.profiles.interview = {
    workspace = "interview";
    workspaces.paused = "tutor";
    start = "05:00";
    from = firstDay;
    days = [
      1
      2
      4
      5
    ];
    password = "c2fGUFHyYmUS3666DRKm347";
    message = "Weekday interviews: finish two of today's three to unlock.";
    releaseCheck = [
      interviewExe
      "check-day"
    ];
    allow = {
      active = [
        { class = "^emacs$"; }
        { class = "^interview%-claude$"; }
      ];
      paused = [
        { class = "^interview%-tutor$"; }
        { class = "^interview%-tutor%-emacs$"; }
      ];
    };
    actions = [
      {
        label = "Open interviewer";
        command = [ (hook "on-engage") ];
      }
      {
        label = "Start next";
        command = [
          interviewExe
          "start"
          "--open"
        ];
      }
      {
        label = "Pause / resume";
        command = [
          interviewExe
          "toggle"
        ];
      }
    ];
    binds = [
      {
        key = "SUPER+F5";
        command = "${interviewExe} toggle";
        description = "pause or resume the interview clock";
        global = true;
      }
      {
        key = "SUPER+F6";
        command = hook "on-engage";
        description = "reopen Emacs and the interviewer";
        global = true;
        substates = [ "active" ];
      }
      {
        key = "SUPER+F6";
        command = lib.getExe onTutor;
        description = "reopen the tutor and its Emacs";
        substates = [ "paused" ];
      }
      {
        key = "SUPER+CTRL+ALT+r";
        command = "${hook "emacs-restart"} main";
        description = "restart the interview Emacs";
        substates = [ "active" ];
      }
      {
        key = "SUPER+CTRL+ALT+r";
        command = "${hook "emacs-restart"} tutor";
        description = "restart the tutor Emacs";
        substates = [ "paused" ];
      }
    ];
    onEngage = [ (hook "on-engage") ];
    settingsFile = "${config.xdg.stateHome}/interview/settings.json";
  };

  systemd.user.services.interview-tutor-emacs = {
    Unit.Description = "Tutor Emacs, a separate daemon that cannot read interview problems or sessions";
    Service = {
      Type = "notify";
      RuntimeDirectory = "interview-tutor-emacs";
      RuntimeDirectoryMode = "0700";
      ExecStartPre = "+${lib.getExe tutorEmacsEnv}";
      ExecStart = "${tutorEmacsRun}";
      Environment = [
        "PATH=${lib.makeBinPath [ pkgs.evcxr ]}:${config.home.profileDirectory}/bin:/run/current-system/sw/bin"
        "INTERVIEW_REPO=${repo}"
        "TUTOR_EMACS=${lib.getExe' emacs "emacs"}"
        "TUTOR_EMACS_STATE=${tutorEmacsState}"
      ];
      InaccessiblePaths = [
        "${repo}/problems"
        "${repo}/sessions"
        "${repo}/.git"
        "-%t/emacs"
        "-%t/hypr"
        "-%t/bus"
        "-%t/systemd/private"
      ];
      PrivateTmp = true;
      Restart = "on-failure";
      SuccessExitStatus = 15;
      TimeoutStartSec = "180s";
      TimeoutStopSec = "10s";
    };
  };
}

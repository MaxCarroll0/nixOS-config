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

  home.packages = [
    interview
    emacsFrame
  ];

  programs.direnv.config.whitelist.prefix = [ "${repo}/sessions" ];

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
    required_per_day = 2;
    lockdown = true;
    review_sections = [
      "Mistakes"
      "Further optimisation"
    ];
    context = "LeetCode-style: well-known algorithm and data-structure classics, climbing the curriculum topic ladder (curriculum.toml) from arrays and hashing to dynamic programming. A prompt is the statement, examples, constraints and the signature; it never hints at the approach, a data structure, an edge case to watch or a trap the problem sets.";
    interviewer = "Act as a friendly, rigorous interviewer at a strong engineering company. Never give a hint unprompted: give one only when the candidate asks or after noticing they have been stuck for a few minutes, and then only the next rung of the hint ladder. Otherwise ask one open question per gap (an input to trace, a case to try); never name the bug, the fix or the failing input. Never write solution code into the candidate's files. Answer language questions with a toy example unrelated to the problem.";
    track_choice = "balanced";
    tracks = [
      {
        name = "ocaml";
        langs = [ "ocaml" ];
        difficulty = "easy-medium";
        progression = "rotate";
        context = "Functional OCaml: at least 75% of problems are solved with immutable data and functional technique (lists, Map and Set functors, folds, recursion, pattern matching, option and result); the rest may need arrays, Hashtbl or ref and say so in the prompt.";
        memory = "No syntax section. Track which functional techniques recent problems exercised and vary them.";
        interviewer = "The candidate is fluent in OCaml: discuss idiom, purity and complexity of persistent structures rather than syntax.";
      }
      {
        name = "systems";
        langs = [
          "rust"
          "c"
        ];
        difficulty = "easy";
        progression = "in order";
        review_sections = [
          "Mistakes"
          "Further optimisation"
          "Taught"
        ];
        context = "Beginner in Rust and C, taught one step at a time. Problems follow a syntax and feature ladder per language and each problem needs at most one or two constructs the taught log has not introduced. C ladder: functions, if, for loops over a pointer and length, out-pointers and bool, integer widths and casts, strings as char arrays, structs, header files (declarations against definitions, include guards or #pragma once, static helpers, a problem where the candidate writes the .h of their own helper module), malloc and free, qsort and function pointers, a hand-written hash table. Rust ladder: fn, slices, Option, for loops, let mut, match, Vec, String and &str, HashMap, ownership and borrowing, iterators and closures, Result. The algorithm stays easy so attention goes on the language.";
        memory = "Taught log: progress/taught.toml. Every construct the problem needs that the log shows in fewer than 3 earlier problems of that language goes in a Useful syntax section of the prompt: the form on a toy example unrelated to the problem and one line on what it does. A construct shown in 3 problems is no longer listed. After each interview, record the problem against every construct its prompt listed and add anything newly taught in conversation.";
        interviewer = "Act as a tutor on the language: explain compiler errors line by line, show the idiom on a toy example when the candidate struggles with the language rather than the algorithm, and build on what the taught log already lists. Algorithmic help still goes through the hint ladder.";
      }
      {
        name = "managed";
        langs = [
          "csharp"
          "python"
        ];
        difficulty = "easy-medium";
        progression = "rotate";
        context = "Idiomatic standard library use: LINQ and collections in C#, built-ins and comprehensions in Python.";
        memory = "No syntax section. Track which library areas recent problems exercised and vary them.";
        interviewer = "Ask about the idiomatic library choice once a working solution exists.";
      }
    ];
    on_pause = [ (hook "on-pause") ];
    on_resume = [ (hook "on-resume") ];
    on_complete = [
      lockdown
      "check"
    ];
    on_start = [ (hook "on-start") ];
    on_close = [ (hook "on-close") ];
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
        label = "Focus interviewer";
        command = [ (hook "focus") ];
      }
      {
        label = "Run tests";
        command = [
          (hook "bar-test")
          "run"
        ];
        phases = [ "coding" ];
      }
      {
        label = "Submit";
        command = [
          (hook "bar-test")
          "submit"
        ];
        phases = [ "coding" ];
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
      {
        label = "End interview";
        command = [
          interviewExe
          "end"
        ];
        phases = [ "review" ];
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

# Weekday interview practice: the interview clock daemon, its hooks, and the lockdown profile that enforces it.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  repo = "${config.home.homeDirectory}/Jobs/general";

  interview = pkgs.writers.writePython3Bin "interview" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../pkgs/interview/interview.py);

  hook =
    name:
    lib.getExe (
      pkgs.writeShellApplication {
        name = "interview-${name}";
        runtimeInputs = [
          config.services.lockdown.package
          pkgs.jq
          pkgs.util-linux
        ];
        runtimeEnv.INTERVIEW_REPO = repo;
        text = builtins.readFile ../pkgs/interview/${name}.sh;
      }
    );

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
    tracks = {
      ocaml = [ "ocaml" ];
      systems = [
        "rust"
        "c"
      ];
      managed = [
        "csharp"
        "python"
      ];
    };
    on_pause = [ (hook "on-pause") ];
    on_resume = [
      lockdown
      "state"
      "interview"
      "active"
    ];
    on_complete = [
      lockdown
      "check"
    ];
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

  services.lockdown.profiles.interview = {
    start = "05:00";
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
      paused = [ { class = "^interview%-tutor$"; } ];
    };
    binds = [
      {
        key = "SUPER+p";
        command = "${interviewExe} toggle";
        description = "pause or resume the interview clock";
      }
      {
        key = "SUPER+Return";
        command = "emacsclient -c -n";
        description = "new Emacs frame";
      }
      {
        key = "SUPER+i";
        command = hook "on-engage";
        description = "reopen Emacs and the interviewer";
      }
    ];
    onEngage = [ (hook "on-engage") ];
  };
}

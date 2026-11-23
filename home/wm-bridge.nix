# Bridge robustness: a watchdog that restarts a wedged Emacs daemon.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.wm;

  stateDir = "\${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}/wm-bridge";

  watchdog = pkgs.writeShellScriptBin "wm-watchdog" ''
    set -u
    dir="${stateDir}"
    counter="$dir/watchdog-fails"
    ${pkgs.coreutils}/bin/mkdir -p "$dir"

    if ${pkgs.coreutils}/bin/timeout ${cfg.watchdogTimeout} emacsclient --eval t > /dev/null 2>&1; then
      if [ -e "$counter" ]; then
        ${pkgs.coreutils}/bin/rm -f "$counter"
        echo "wm-watchdog: Emacs responsive again"
      fi
      exit 0
    fi

    fails=$(${pkgs.coreutils}/bin/cat "$counter" 2> /dev/null || echo 0)
    fails=$((fails + 1))
    echo "$fails" > "$counter"
    echo "wm-watchdog: Emacs unresponsive, consecutive failures $fails"

    if [ $((fails % ${toString cfg.watchdogFailures})) = 0 ]; then
      echo "wm-watchdog: restarting emacs.service"
      systemctl --user --no-block restart emacs.service
      ${pkgs.libnotify}/bin/notify-send --urgency=critical \
        "Emacs daemon restarted" \
        "No reply for $((fails * ${cfg.watchdogInterval}))s, so the watchdog restarted it. SUPER+CTRL+ALT+R restarts it by hand." \
        || true
    fi
  '';
in
{
  options.local.wm = {
    watchdogTimeout = lib.mkOption {
      type = lib.types.str;
      default = "2";
      description = "Seconds the watchdog waits for the Emacs daemon to answer.";
    };

    watchdogInterval = lib.mkOption {
      type = lib.types.str;
      default = "30";
      description = "Seconds between watchdog pings.";
    };

    watchdogFailures = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = "Consecutive failed pings after which the watchdog restarts emacs.service, and again after each further run of as many.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ watchdog ];

    systemd.user.services.emacs.Service.TimeoutStopSec = "15s";

    systemd.user.services.wm-watchdog = {
      Unit.Description = "Restart a wedged Emacs daemon";
      Service = {
        Type = "oneshot";
        ExecStart = "${watchdog}/bin/wm-watchdog";
      };
    };

    systemd.user.timers.wm-watchdog = {
      Unit.Description = "Ping the Emacs daemon periodically";
      Timer = {
        OnStartupSec = cfg.watchdogInterval;
        OnUnitInactiveSec = cfg.watchdogInterval;
      };
      Unit.PartOf = [ "hyprland-session.target" ];
      Install.WantedBy = [ "hyprland-session.target" ];
    };
  };
}

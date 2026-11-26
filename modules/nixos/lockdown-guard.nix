# Root side of the lockdown: while the user's lockdown is due, deny root and kill recreational apps launched inside it.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.lockdownGuard;

  lockdown = pkgs.writers.writePython3Bin "lockdown" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../../pkgs/lockdown/lockdown.py);

  flag = "/run/lockdown-guard/engaged";

  home = config.users.users.${cfg.user}.home;
  uid = toString cfg.uid;

  guard = pkgs.writeShellApplication {
    name = "lockdown-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.getconf
      pkgs.util-linux
      pkgs.systemd
    ];
    text = ''
      set +e
      engaged=$(runuser -u ${cfg.user} -- env -i \
        HOME=${home} \
        XDG_RUNTIME_DIR=/run/user/${uid} \
        PATH=/etc/profiles/per-user/${cfg.user}/bin:/run/current-system/sw/bin \
        ${lib.getExe lockdown} engaged 2>/dev/null)
      due=$?
      set -e
      if [ "$due" -ne 0 ]; then
        [ "$due" -eq 1 ] || echo "lockdown engaged check failed with $due; leaving root open" >&2
        rm -f ${flag}
        exit 0
      fi
      touch ${flag}
      since=$(awk 'NR == 1 || $2 < min { min = $2 } END { print min }' <<<"$engaged")
      btime=$(awk '/^btime / { print $2 }' /proc/stat)
      hz=$(getconf CLK_TCK)
      apps=" ${lib.concatStringsSep " " cfg.apps} "
      app() {
        local comm argv0 name
        comm=$(cat "/proc/$1/comm" 2>/dev/null) || return 1
        argv0=$(tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | head -n 1)
        for name in "$comm" "$(basename -- "''${argv0:-x}")"; do
          name=''${name#.}
          name=''${name%%-wrap*}
          case "$apps" in
            *" $name "*) echo "$name"; return 0 ;;
          esac
        done
        return 1
      }
      started() {
        local stat fields
        stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
        read -ra fields <<<"''${stat##*) }"
        echo $((btime + fields[19] / hz)) "''${fields[1]}"
      }
      launched_inside() {
        local pid=$1 at parent
        while [ "$pid" -gt 1 ]; do
          read -r at parent < <(started "$pid") || return 1
          if [ "$at" -lt "$since" ] && app "$pid" >/dev/null; then return 1; fi
          pid=$parent
        done
        return 0
      }
      for proc in /proc/[0-9]*; do
        pid=''${proc#/proc/}
        [ "$(stat -c %u "$proc" 2>/dev/null)" = ${uid} ] || continue
        name=$(app "$pid") || continue
        launched_inside "$pid" || continue
        kill -KILL "$pid" 2>/dev/null || true
        echo "killed $name ($pid)"
      done
      if [ ! -e /run/user/${uid}/lockdown/active.json ]; then
        systemctl --user -M ${cfg.user}@ start lockdown.timer lockdown.service || true
      fi
    '';
  };

  deny = pkgs.writeShellScript "lockdown-guard-pam" ''
    [ -e ${flag} ] || exit 0
    [ "$1" = root-only ] && [ "$PAM_USER" != root ] && exit 0
    echo "lockdown: root is unavailable until today's interviews are done"
    exit 1
  '';

  rule = args: {
    order = 0;
    control = "requisite";
    modulePath = "${pkgs.linux-pam}/lib/security/pam_exec.so";
    args = [
      "stdout"
      "${deny}"
    ]
    ++ args;
  };
in
{
  options.local.lockdownGuard = {
    enable = lib.mkEnableOption "the root side of the lockdown";
    user = lib.mkOption {
      type = lib.types.str;
      default = "max";
      description = "User whose lockdown profiles decide when root is denied.";
    };
    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "Numeric id of that user, for its runtime directory and process ownership.";
    };
    apps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Process names killed when launched while the lockdown is due, matched on comm and argv[0] without a nix wrapper prefix or suffix; ones already running when it engaged are spared.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d /run/lockdown-guard 0755 root root - -" ];

    systemd.services.lockdown-guard = {
      description = "Deny root and kill recreational apps launched while the lockdown is due";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe guard;
        TimeoutStartSec = "60s";
      };
    };

    systemd.timers.lockdown-guard = {
      description = "Evaluate the root side of the lockdown every 10 seconds";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10s";
        OnUnitActiveSec = "10s";
        AccuracySec = "1s";
      };
    };

    security.pam.services = {
      sudo.rules.account.lockdown-guard = rule [ ];
      su.rules.account.lockdown-guard = rule [ ];
      polkit-1.rules.account.lockdown-guard = rule [ ];
      systemd-run0.rules.account.lockdown-guard = rule [ ];
      login.rules.account.lockdown-guard = rule [ "root-only" ];
      sshd.rules.account.lockdown-guard = rule [ "root-only" ];
    };
  };
}

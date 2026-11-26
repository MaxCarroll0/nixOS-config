# Root side of the lockdown: while the user's lockdown is due, deny root.

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
      pkgs.util-linux
      pkgs.systemd
    ];
    text = ''
      set +e
      runuser -u ${cfg.user} -- env -i \
        HOME=${home} \
        XDG_RUNTIME_DIR=/run/user/${uid} \
        PATH=/etc/profiles/per-user/${cfg.user}/bin:/run/current-system/sw/bin \
        ${lib.getExe lockdown} engaged >/dev/null 2>&1
      due=$?
      set -e
      if [ "$due" -ne 0 ]; then
        [ "$due" -eq 1 ] || echo "lockdown engaged check failed with $due; leaving root open" >&2
        rm -f ${flag}
        exit 0
      fi
      touch ${flag}
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
      description = "Numeric id of that user, for its runtime directory.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d /run/lockdown-guard 0755 root root - -" ];

    systemd.services.lockdown-guard = {
      description = "Deny root while the lockdown is due";
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

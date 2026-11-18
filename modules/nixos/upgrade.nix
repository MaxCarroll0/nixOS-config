# Daily upgrade of the running revision to origin's inputs, staged session-safe, with a reboot check.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.upgrade;
  flakePath = "/home/max/.config/nix";
  collectors = import ./monitoring/collector-lib.nix { inherit pkgs lib; };

  upgrade = pkgs.writeShellApplication {
    name = "nixos-upgrade-running";
    runtimeEnv = {
      UPGRADE_FLAKE = flakePath;
      UPGRADE_HOST = config.networking.hostName;
      UPGRADE_SESSION_SAFE = if cfg.sessionSafe then "1" else "0";
    };
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.git
      pkgs.gnugrep
      pkgs.jq
      pkgs.openssh
      pkgs.util-linux
    ];
    text = builtins.readFile ./deploy/claim.sh + builtins.readFile ./upgrade/upgrade.sh;
  };

  rebootNeeded = pkgs.writeShellApplication {
    name = "reboot-needed";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
    ];
    text = builtins.readFile ./upgrade/reboot-needed.sh;
  };

  applyStaged = pkgs.writeShellApplication {
    name = "apply-staged-system";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.systemd
    ];
    text = builtins.readFile ./upgrade/apply-staged.sh;
  };

  rebootMetric = collectors.writeCollector "reboot-required" [ ] ''
    ${lib.getExe rebootNeeded} --metric
  '';
in
{
  options.local.upgrade = {
    sessionSafe = lib.mkOption {
      type = lib.types.bool;
      default = config.services.displayManager.sddm.enable;
      description = "Whether upgrades that would restart systemd or user units are staged for the next logout or boot instead of switched live.";
    };
    rebootWhenNeeded = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Sun *-*-* 05:00:00";
      description = "OnCalendar time to reboot when reboot-needed reports a staged kernel, initrd or generation; null never reboots.";
    };
  };

  config = lib.mkMerge [
    {
      environment.systemPackages = [ rebootNeeded ];
    }

    (lib.mkIf config.system.autoUpgrade.enable {
      system.autoUpgrade = {
        allowReboot = false;
        flake = "git+file://${flakePath}";
        dates = "daily";
        randomizedDelaySec = "45min";
      };

      systemd.services.nixos-upgrade = {
        script = lib.mkForce "exec ${lib.getExe upgrade}";
        serviceConfig = {
          StateDirectory = "nixos-upgrade";
          MemoryHigh = "3G";
          CPUWeight = "idle";
        };
      };
    })

    (lib.mkIf cfg.sessionSafe {
      systemd.services.apply-staged-system = {
        description = "Switch to a staged system once no graphical session is open";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe applyStaged;
        };
      };

      systemd.user.services.apply-staged-at-logout = {
        description = "Apply a staged system when the graphical session ends";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
          ExecStop = "${pkgs.systemd}/bin/systemctl start --no-block apply-staged-system.service";
        };
      };

      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units"
              && action.lookup("unit") == "apply-staged-system.service"
              && action.lookup("verb") == "start"
              && subject.user == "max") {
            return polkit.Result.YES;
          }
        });
      '';
    })

    (lib.mkIf (cfg.rebootWhenNeeded != null) {
      systemd.services.reboot-when-needed = {
        description = "Reboot into a staged kernel or generation";
        serviceConfig = {
          Type = "oneshot";
          ExecCondition = lib.getExe rebootNeeded;
          ExecStart = "${pkgs.systemd}/bin/systemctl reboot";
        };
      };
      systemd.timers.reboot-when-needed = {
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = cfg.rebootWhenNeeded;
      };
    })

    (lib.mkIf (config.local.monitoring.exporter.enable or false) {
      systemd.services.textfile-reboot-required = collectors.collectorService rebootMetric;
      systemd.timers.textfile-reboot-required = collectors.collectorTimer "5min";
    })
  ];
}

{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.local.fancontrol;

  releaseFans = pkgs.writeShellScript "fan2go-release-fans" ''
    for enable in /sys/class/hwmon/*/pwm*_enable; do
      echo 2 > "$enable" 2>/dev/null || true
    done
  '';
in
{
  options.local.fancontrol.enable = lib.mkEnableOption "fan2go daemon";
  options.local.fancontrol.configFile = lib.mkOption {
    type = lib.types.path;
    description = "Path to the fan2go config for this host.";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.fan2go = {
      after = [ "systemd-udev-settle.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.fan2go}/bin/fan2go -c ${cfg.configFile}";
        # fan2go 0.13.0 blocks forever on SIGTERM restoring control mode on fans
        # whose driver cannot write it, so it gets killed holding a manual PWM.
        TimeoutStopSec = 10;
        ExecStopPost = "${releaseFans}";
        StateDirectory = "fan2go";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # The EC restores its own defaults across a resume, so the fans run up until
    # fan2go's next tick notices and pulls them back down.
    powerManagement.resumeCommands = "${pkgs.systemd}/bin/systemctl restart fan2go.service";
  };
}

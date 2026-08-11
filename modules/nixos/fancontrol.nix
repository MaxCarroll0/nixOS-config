{ config, pkgs, lib, ... }:
let
  cfg = config.local.fancontrol;
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
        StateDirectory = "fan2go";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}

{ config, pkgs, lib, ... }:
let
  cfg = config.local.fancontrol;
in
{
  options.local.fancontrol.enable = lib.mkEnableOption "fan2go daemon";

  config = lib.mkIf cfg.enable {
    systemd.services.fan2go = {
      after = [ "systemd-udev-settle.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.fan2go}/bin/fan2go -c ${../../hosts/desktop/fan2go.yaml}";
        StateDirectory = "fan2go";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}

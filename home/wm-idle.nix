# Hyprland idle: blank the monitors without touching the session.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.wm;
in
{
  options.local.wm.idle.displayOffSeconds = lib.mkOption {
    type = lib.types.int;
    default = 300;
    description = "Idle seconds before the monitors blank.";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.hypridle ];

    xdg.configFile."hypr/hypridle.conf".text = ''
      general {
          ignore_dbus_inhibit = false
          ignore_systemd_inhibit = false
      }

      listener {
          timeout = ${toString cfg.idle.displayOffSeconds}
          on-timeout = hyprctl dispatch dpms off
          on-resume = hyprctl dispatch dpms on
      }
    '';

    systemd.user.services.hypridle = {
      Unit = {
        Description = "Hyprland idle daemon";
        PartOf = [ "hyprland-session.target" ];
        After = [ "hyprland-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.hypridle}/bin/hypridle";
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "hyprland-session.target" ];
    };
  };
}

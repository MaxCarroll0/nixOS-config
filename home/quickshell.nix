# Quickshell: the session's shell surfaces, fed by generated JSON.

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
  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.quickshell ];

    xdg.configFile."quickshell/shell.qml".source = ../quickshell/shell.qml;

    systemd.user.services.quickshell = {
      Unit = {
        Description = "Quickshell desktop surfaces";
        PartOf = [ "hyprland-session.target" ];
        After = [ "hyprland-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.quickshell}/bin/quickshell -p %h/.config/quickshell/shell.qml";
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "hyprland-session.target" ];
    };
  };
}

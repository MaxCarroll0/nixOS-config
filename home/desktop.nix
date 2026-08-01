# Home for the AMD desktop.

{ ... }:

{
  imports = [ ./common.nix ];

  programs.btop = {
    enable = true;
    settings = {
      color_theme = "gruvbox_light";
      disable_mouse = true;
      freq_mode = "range";
      graph_symbol = "braille";
      proc_sorting = "cpu direct";
      vim_keys = true;
    };
  };

  xdg.configFile."powerdevilrc" = {
    force = true;
    text = ''
      [AC][Display]
      DimDisplayIdleTimeoutSec=120
      DimDisplayWhenIdle=true
      TurnOffDisplayIdleTimeoutSec=300
      TurnOffDisplayIdleTimeoutWhenLockedSec=30
      TurnOffDisplayWhenIdle=true

      [AC][SuspendAndShutdown]
      AutoSuspendAction=0
    '';
  };
}

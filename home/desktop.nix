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
  xdg.configFile."btop/btop.conf".force = true;

  xdg.configFile."s-tui/s-tui.conf" = {
    force = true;
    text = ''
      [GraphControl]
      refresh = 2.0
      utf8 = True

      [Temp,Graphs]
      edge,0 = True
      iwlwifi_1,0 = True
      tctl,0 = True
      composite,0 = True

      [Frequency,Graphs]
      avg = True
      core 0 = True
      core 1 = True
      core 2 = True
      core 3 = True
      core 4 = True
      core 5 = True
      core 6 = True
      core 7 = True
      core 8 = True
      core 9 = True
      core 10 = True
      core 11 = True

      [Util,Graphs]
      avg = True
      core 0 = True
      core 1 = True
      core 2 = True
      core 3 = True
      core 4 = True
      core 5 = True
      core 6 = True
      core 7 = True
      core 8 = True
      core 9 = True
      core 10 = True
      core 11 = True

      [Power,Graphs]

      [Fan,Graphs]
      amdgpu,0 = True

      [Temp,Summaries]
      edge,0 = True
      iwlwifi_1,0 = True
      tctl,0 = True
      composite,0 = True

      [Frequency,Summaries]
      avg = True
      core 0 = True
      core 1 = True
      core 2 = True
      core 3 = True
      core 4 = True
      core 5 = True
      core 6 = True
      core 7 = True
      core 8 = True
      core 9 = True
      core 10 = True
      core 11 = True

      [Util,Summaries]
      avg = True
      core 0 = True
      core 1 = True
      core 2 = True
      core 3 = True
      core 4 = True
      core 5 = True
      core 6 = True
      core 7 = True
      core 8 = True
      core 9 = True
      core 10 = True
      core 11 = True

      [Power,Summaries]

      [Fan,Summaries]
      amdgpu,0 = True
    '';
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

# Home for the AMD desktop.

{ ... }:

{
  imports = [ ./common.nix ];

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

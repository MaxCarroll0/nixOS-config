# Home for the ThinkPad.

{ ... }:

{
  imports = [ ./common.nix ];

  local.nasAlerts.enable = true;
  local.wm.enable = true;
}

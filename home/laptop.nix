# Home for the ThinkPad.

{ ... }:

{
  imports = [
    ./common.nix
    ./interview.nix
  ];

  local.nasAlerts.enable = true;
  local.wm.enable = true;
}

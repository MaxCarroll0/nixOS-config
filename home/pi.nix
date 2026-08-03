# Home for the Pi: base only, no GUI.

{ ... }:

{
  imports = [ ./base.nix ];

  local.emacs.guiToolkit = false;
}

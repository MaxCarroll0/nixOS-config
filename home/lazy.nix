{ lib, ... }:

{
  options.local.lazy.zoom.enable = lib.mkEnableOption "building Zoom on first launch instead of at activation";
}

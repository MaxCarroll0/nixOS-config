# Browser sync store: a per-host drop box the GUI hosts push Chromium state to.

{
  config,
  lib,
  ...
}:
let
  cfg = config.local.browserSync;
in
{
  options.local.browserSync.server = lib.mkEnableOption "browser sync store for this host";
  options.local.browserSync.path = lib.mkOption {
    type = lib.types.path;
    default = "/srv/browser-sync";
    description = "Directory holding each host's pushed browser state.";
  };

  config = lib.mkIf cfg.server {
    systemd.tmpfiles.rules = [ "d ${cfg.path} 0700 max users -" ];
  };
}

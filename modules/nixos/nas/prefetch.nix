# Read-ahead: an open warms its folder, so a spun-up disk serves the rest of it from cache.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas;
  pcfg = cfg.prefetch;
  scfg = cfg.storage;

  branches = lib.attrNames scfg.dataDisks;

  mountUnit =
    name:
    "${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" "${scfg.diskRoot}/${name}")}.mount";

  warm = pkgs.writeShellApplication {
    name = "nas-prefetch";
    runtimeInputs = [
      pkgs.fatrace
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
    ];
    text = builtins.replaceStrings [ "@metricsFile@" "@ignoreCommands@" "@cooldownSeconds@" "@maxBytes@" "@maxFiles@" ] [ pcfg.metricsFile (lib.concatStringsSep " | " pcfg.ignoreCommands) (toString pcfg.cooldownSeconds) (toString pcfg.maxBytes) (toString pcfg.maxFiles) ] (builtins.readFile ./nas-prefetch.sh);
  };
in

{
  options.local.nas.prefetch = {
    enable = lib.mkEnableOption "warming a folder into cache when one of its files is opened";

    cooldownSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "How long a folder is left alone after warming; this is what breaks the feedback loop.";
    };

    maxFiles = lib.mkOption {
      type = lib.types.ints.positive;
      default = 40;
      description = "Most siblings warmed per open.";
    };

    maxBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 512 * 1024 * 1024;
      description = "Byte budget per open, so one large folder cannot evict the whole cache.";
    };

    ignoreCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "snapraid"
        "nas-prefetch"
        "dd"
        "fatrace"
        "rsync"
      ];
      description = "Bulk readers whose opens must not trigger read-ahead; a scrub would otherwise warm the whole array.";
    };

    metricsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter-textfile/nas-prefetch.prom";
      description = "Textfile collector output for read-ahead counters.";
    };
  };

  config = lib.mkIf (cfg.enable && pcfg.enable) {
    systemd.services = lib.listToAttrs (
      map (name: {
        name = "nas-prefetch-${name}";
        value = {
          description = "Warm folders on ${name} when a file is opened";
          wantedBy = [
            (mountUnit name)
            "multi-user.target"
          ];
          partOf = [ (mountUnit name) ];
          after = [ (mountUnit name) ];
          unitConfig.ConditionPathIsMountPoint = "${scfg.diskRoot}/${name}";
          serviceConfig = {
            ExecStart = "${lib.getExe warm} ${scfg.diskRoot}/${name}";
            WorkingDirectory = "${scfg.diskRoot}/${name}";
            Restart = "on-failure";
            RestartSec = 30;
            Nice = 19;
            IOSchedulingClass = "idle";
            MemoryMax = "64M";
          };
        };
      }) branches
    );
  };
}

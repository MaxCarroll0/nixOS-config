# dev-build: run a project's own incremental build here or on a remote builder.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  facts = import ../../hosts/facts.nix;
  selfName = config.networking.hostName;
  cfg = config.local.devBuild;

  builderFacts = facts.${cfg.builder} or { };
  nativeSystem = f: lib.head ((f.systems or [ ]) ++ [ null ]);
  selfSystem = nativeSystem (facts.${selfName} or { });

  canOffload =
    cfg.builder != selfName
    && (builderFacts.tailscale or "") != ""
    && selfSystem != null
    && selfSystem == nativeSystem builderFacts;

  excludes = pkgs.writeText "dev-build-excludes" ''
    .direnv/
    .stack-work/
    .venv/
    __pycache__/
    _build/
    dist-newstyle/
    node_modules/
    result
    result-*
    target/
    *.log
    .dev-build-*
  '';

  devBuild = pkgs.writeShellApplication {
    name = "dev-build";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      git
      gnugrep
      gnused
      openssh
      rsync
    ];
    runtimeEnv = {
      DEV_BUILD_BUILDER = cfg.builder;
      DEV_BUILD_BUILDER_ADDRESS = builderFacts.tailscale or "";
      DEV_BUILD_CAN_OFFLOAD = if canOffload then "1" else "0";
      DEV_BUILD_DEFAULT_THRESHOLD = toString cfg.thresholdSeconds;
      DEV_BUILD_REMOTE_ROOT = cfg.remoteRoot;
      DEV_BUILD_EXCLUDES = excludes;
    };
    excludeShellChecks = [
      "SC2016"
      "SC2029"
    ];
    text = builtins.readFile ./dev-build.sh;
  };
in
{
  options.local.devBuild = {
    builder = lib.mkOption {
      type = lib.types.str;
      default = "desktopnew";
      description = "Host that runs the incremental builds this one defers.";
    };

    thresholdSeconds = lib.mkOption {
      type = lib.types.int;
      default = 90;
      description = "A build recorded at or above this many seconds goes to the builder.";
    };

    remoteRoot = lib.mkOption {
      type = lib.types.str;
      default = "/home/max/offload";
      description = "Directory on the builder holding the synced worktrees.";
    };
  };

  config.environment.systemPackages = [
    devBuild
    pkgs.rsync
  ];
}

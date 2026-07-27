# Nix remote builder: a shell-less account restricted to the daemon protocol.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.build.host;

  # The key buys a Nix protocol session, not a shell. This must stay in step
  # with protocol = "ssh-ng" on the client; plain ssh:// wants nix-store --serve.
  forcedCommand = key: ''command="${config.nix.package}/bin/nix-daemon --stdio",restrict ${key}'';
in

{
  options.local.build.host = {
    enable = lib.mkEnableOption "acting as a Nix remote builder";

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Public keys of the root users allowed to submit builds.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.nixremote = {
      isSystemUser = true;
      group = "nixremote";
      shell = pkgs.bashInteractive;
      openssh.authorizedKeys.keys = map forcedCommand cfg.authorizedKeys;
    };
    users.groups.nixremote = { };

    local.server.ssh.allowUsers = [ "nixremote" ];

    # trusted-users lets the client push unsigned paths and override settings.
    # That is a trust relationship between two machines you own, not a sandbox.
    nix.settings.trusted-users = [ "nixremote" ];
    nix.nrBuildUsers = 64;

    nix.settings = {
      max-jobs = "auto";
      cores = 0;
      sandbox = true;
      sandbox-fallback = false;
      min-free = 10 * 1024 * 1024 * 1024;
      max-free = 200 * 1024 * 1024 * 1024;
      auto-allocate-uids = true;
      experimental-features = [
        "auto-allocate-uids"
        "cgroups"
      ];
      use-cgroups = true;
    };

    assertions = [
      {
        assertion = cfg.authorizedKeys != [ ];
        message = "local.build.host.authorizedKeys is empty; the builder would accept nobody.";
      }
    ];
  };
}

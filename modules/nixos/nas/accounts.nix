# NAS accounts: declarative Unix users with explicit uids, one private home each.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas;

  homeOf = name: "${cfg.dataRoot}/${name}";

  managed = lib.filterAttrs (_: a: !a.systemUser);

  groupOf = name: a: if a.systemUser then (config.users.users.${name}.group or name) else name;
in

{
  options.local.nas = {
    enable = lib.mkEnableOption "NAS accounts and their private homes";

    dataRoot = lib.mkOption {
      type = lib.types.str;
      default = "/srv/data";
      description = "Root of the merged data tree holding per-user homes.";
    };

    accounts = lib.mkOption {
      default = { };
      description = "NAS accounts, keyed by username.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              uid = lib.mkOption {
                type = lib.types.nullOr (lib.types.ints.between 3000 3999);
                default = null;
                description = "Stable uid, identical on every node so replication preserves ownership. Null for an existing system user.";
              };

              systemUser = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Use an existing Unix user of this name rather than creating one; its uid is left alone.";
              };

              tailscaleLogin = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Tailscale-User-Login this account answers to, for identity-header auth in the web tier.";
              };

              description = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "Human-readable name for the account.";
              };

              hashedPasswordFile = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Path to the hashed login password, normally a sops secret.";
              };

              quotaBytes = lib.mkOption {
                type = lib.types.nullOr lib.types.ints.positive;
                default = null;
                description = "Advisory size budget surfaced in dashboards; not enforced by the filesystem.";
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          let
            uids = lib.mapAttrsToList (_: a: a.uid) (managed cfg.accounts);
          in
          lib.length (lib.unique uids) == lib.length uids;
        message = "local.nas.accounts: uids must be unique, since they are mirrored across nodes.";
      }
      {
        assertion = lib.all (a: a.uid != null) (lib.attrValues (managed cfg.accounts));
        message = "local.nas.accounts: a uid is required unless systemUser is set.";
      }
    ];

    users.groups = lib.mapAttrs (_: a: { gid = a.uid; }) (managed cfg.accounts);

    users.users = lib.mapAttrs (name: a: {
      inherit (a) uid description;
      inherit (a) hashedPasswordFile;
      group = name;
      isNormalUser = true;
      home = homeOf name;
      createHome = false;
      homeMode = "0700";
      shell = "${pkgs.shadow}/bin/nologin";
    }) (managed cfg.accounts);

    systemd.tmpfiles.rules = lib.mapAttrsToList (
      name: a: "d ${homeOf name} 0700 ${name} ${groupOf name a} - -"
    ) cfg.accounts;

    environment.etc."nas/identity-map".text = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: a: "${a.tailscaleLogin} ${name}") (
        lib.filterAttrs (_: a: a.tailscaleLogin != null) cfg.accounts
      )
    );
  };
}

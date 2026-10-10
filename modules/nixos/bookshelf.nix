# Catalogue of books and sheet music: loopback service, tailnet-only vhost, nightly dump.

{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

let
  cfg = config.local.bookshelf;

  environment = {
    BOOKSHELF_DATABASE = cfg.databasePath;
    BOOKSHELF_CURRENCY = cfg.currency;
    BOOKSHELF_RESOLVERS = lib.concatStringsSep "," cfg.resolvers;
    BOOKSHELF_COMPS_PROVIDERS = lib.concatStringsSep "," cfg.compsProviders;
    BOOKSHELF_SCRAPERS = if cfg.scrapers then "1" else "0";
  };

  dump = pkgs.writeShellApplication {
    name = "bookshelf-dump";
    runtimeInputs = [
      pkgs.sqlite
      pkgs.coreutils
    ];
    # A text dump of the durable tables only, named explicitly rather than filtered out
    # of a full dump: a CREATE TABLE spans several lines, so filtering by line leaves
    # half a statement behind and the result will not restore.
    #
    # The response cache and the full-text index are derived -- the first refetches, the
    # second is rebuilt by --reindex -- and both would dwarf the catalogue in a history.
    #
    # Not a read-only connection: opening a WAL database with mode=ro fails when no
    # writer holds the -shm file open, which is exactly the service-stopped case.
    text = ''
      target=''${1:?usage: bookshelf-dump <file.sql>}
      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT

      tables=$(sqlite3 ${cfg.databasePath} "
        SELECT group_concat(name, ' ') FROM (
          SELECT name FROM sqlite_master
          WHERE type = 'table'
            AND name NOT LIKE 'sqlite_%'
            AND name NOT LIKE 'search%'
            AND name <> 'http_cache'
          ORDER BY name
        )")

      if [ -z "$tables" ]; then
        echo "no tables to dump; is ${cfg.databasePath} initialised?" >&2
        exit 1
      fi

      # shellcheck disable=SC2086
      sqlite3 ${cfg.databasePath} ".dump $tables" > "$tmp"
      install -m 0640 "$tmp" "$target"
    '';
  };

  backup = pkgs.writeShellApplication {
    name = "bookshelf-backup";
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
      pkgs.openssh
    ];
    # A text dump, not the binary file: git stores a readable diff of what changed and
    # a few edits cost a few lines rather than a fresh copy of the whole database.
    text = ''
      repo=${cfg.backup.workTree}
      install -d -m 0700 "$repo"

      if [ ! -d "$repo/.git" ]; then
        git -C "$repo" init -q -b main
        git -C "$repo" config user.name "${cfg.backup.authorName}"
        git -C "$repo" config user.email "${cfg.backup.authorEmail}"
      fi

      ${lib.getExe dump} "$repo/bookshelf.sql"

      git -C "$repo" add -A
      if git -C "$repo" diff --cached --quiet; then
        echo "no changes since the last backup"
        exit 0
      fi

      rows=$(git -C "$repo" diff --cached --numstat -- bookshelf.sql | cut -f1-2)
      git -C "$repo" commit -q -m "bookshelf: $(date -u +%Y-%m-%dT%H:%MZ) ($rows lines changed)"
      echo "committed: $rows lines changed"

      ${lib.optionalString (cfg.backup.remote != null) ''
        key="$CREDENTIALS_DIRECTORY/ssh-key"
        if [ ! -r "$key" ]; then
          echo "warning: ${cfg.backup.identityFile} was not loadable; the commit is local only" >&2
          exit 0
        fi
        # A failed push must not fail the unit: the commit is already made and the next
        # run will carry it, so a flaky network costs nothing.
        GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
          git -C "$repo" push -q "${cfg.backup.remote}" HEAD:${cfg.backup.branch} \
          || { echo "push failed; the commit is local and will go next time" >&2; exit 0; }
        echo "pushed to ${cfg.backup.remote}"
      ''}
    '';
  };

  # lib.hasPrefix compares strings, which makes /var/lib/bookshelf-backup look like it
  # sits under /var/lib/bookshelf. Paths have to be compared at a component boundary.
  under = parent: path: path == parent || lib.hasPrefix "${parent}/" path;

  hardening = {
    CapabilityBoundingSet = [ "" ];
    AmbientCapabilities = [ "" ];
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    DevicePolicy = "closed";
    ProtectProc = "invisible";
    ProcSubset = "pid";
    ProtectClock = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    RemoveIPC = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    UMask = "0077";
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "~@resources"
    ];
    # AF_NETLINK because glibc asks the kernel over netlink whether the host has usable
    # IPv6 before it will resolve anything; without it name resolution fails oddly.
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
      "AF_NETLINK"
    ];
  };
in

{
  options.local.bookshelf = {
    enable = lib.mkEnableOption "the book and sheet-music catalogue";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage "${inputs.bookshelf}/package.nix" { };
      description = "The catalogue application, built against this host's nixpkgs.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8090;
      description = "Loopback port the application listens on; never bind this elsewhere.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "bookshelf";
      description = "Account owning the catalogue; static so the file survives a uid change.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/bookshelf";
      description = "Directory holding the catalogue, kept off the spinning array.";
    };

    databasePath = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.stateDir}/bookshelf.db";
      description = "SQLite file the service reads and the backup job dumps.";
    };

    currency = lib.mkOption {
      type = lib.types.str;
      default = "GBP";
      description = "Currency every figure is reported in.";
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "160M";
      description = "Hard ceiling, above which the cgroup is killed rather than swapping the box.";
    };

    resolvers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "dnb"
        "isbn"
        "freetext"
        "publisher"
      ];
      description = "Identification sources to try, in order.";
    };

    compsProviders = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "ebay" ];
      description = "Used-price sources the refresh job may ask.";
    };

    scrapers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow the providers that scrape sites offering no API.";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "bookshelf";
      description = "Virtual host serving the catalogue on the tailnet.";
    };

    serverAliases = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "books" ];
      description = "Extra names the vhost answers to, matching the hosts-file aliases.";
    };

    tailnetAddress = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Tailnet address nginx listens on; the only address it is reachable at.";
    };

    tailnetPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Extra tailnet port, so a phone with no hosts file can reach it by node name.";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "tailscale0";
      description = "Interface the catalogue is reachable on; never the public one.";
    };

    identityLogin = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Tailscale login injected as the request identity, as the app trusts the header.";
    };

    apiKeySecrets = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Environment variable to sops secret name, for the sources needing a key.";
    };

    refresh = {
      enable = lib.mkEnableOption "the nightly price refresh and revaluation";

      startAt = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 02:40:00";
        description = "When the refresh runs; before the array wakes for its parity sync.";
      };

      memoryMax = lib.mkOption {
        type = lib.types.str;
        default = "384M";
        description = "Ceiling for the refresh, which loads a scientific stack the service does not.";
      };
    };

    backup = {
      enable = lib.mkEnableOption "a daily commit of the catalogue to a git repository";

      workTree = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/bookshelf-backup";
        description = "Git work tree holding the dump; its history is the backup.";
      };

      remote = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "git@github.com:MaxCarroll0/bookshelf-data.git";
        description = "SSH remote to push to; null keeps the history local to this host.";
      };

      branch = lib.mkOption {
        type = lib.types.str;
        default = "main";
        description = "Branch to push the dump to.";
      };

      # TODO: this is the host's own account key, so it can reach every repository
      # the account can. Swap it for a deploy key scoped to the backup repository.
      identityFile = lib.mkOption {
        type = lib.types.str;
        default = "/home/max/.ssh/id_ed25519";
        description = "SSH key the push authenticates with.";
      };

      authorName = lib.mkOption {
        type = lib.types.str;
        default = "bookshelf";
        description = "Commit author name.";
      };

      authorEmail = lib.mkOption {
        type = lib.types.str;
        default = "bookshelf@localhost";
        description = "Commit author address.";
      };

      startAt = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 03:10:00";
        description = "When the backup runs; after the refresh and before the parity sync.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = cfg.stateDir;
      description = "Book and sheet-music catalogue";
    };
    users.groups.${cfg.user} = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.user} - -"
    ]
    ++ lib.optional cfg.backup.enable "d ${cfg.backup.workTree} 0700 ${cfg.user} ${cfg.user} - -";

    sops.secrets = lib.genAttrs (lib.attrValues cfg.apiKeySecrets) (_: {
      restartUnits = [ "bookshelf.service" ];
    });

    sops.templates = lib.optionalAttrs (cfg.apiKeySecrets != { }) {
      "bookshelf-env" = {
        content = lib.concatStrings (
          lib.mapAttrsToList (
            variable: secret: "${variable}=${config.sops.placeholder.${secret}}\n"
          ) cfg.apiKeySecrets
        );
        owner = cfg.user;
        restartUnits = [ "bookshelf.service" ];
      };
    };

    systemd.services.bookshelf = {
      description = "Book and sheet-music catalogue";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      inherit environment;
      serviceConfig = hardening // {
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe cfg.package)
          "--listen 127.0.0.1"
          "--port ${toString cfg.port}"
          "--database ${cfg.databasePath}"
        ];
        EnvironmentFile = lib.mkIf (cfg.apiKeySecrets != { }) config.sops.templates."bookshelf-env".path;
        User = cfg.user;
        Group = cfg.user;
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 10;
        MemoryMax = cfg.memoryMax;
        WorkingDirectory = cfg.stateDir;
        ReadWritePaths = [ cfg.stateDir ];
      };
    };

    systemd.services.bookshelf-refresh = lib.mkIf cfg.refresh.enable {
      description = "Refresh catalogue prices and revalue";
      after = [
        "network-online.target"
        "bookshelf.service"
      ];
      wants = [ "network-online.target" ];
      inherit environment;
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${lib.getExe cfg.package} --refresh --database ${cfg.databasePath}";
        EnvironmentFile = lib.mkIf (cfg.apiKeySecrets != { }) config.sops.templates."bookshelf-env".path;
        User = cfg.user;
        Group = cfg.user;
        MemoryMax = cfg.refresh.memoryMax;
        WorkingDirectory = cfg.stateDir;
        ReadWritePaths = [ cfg.stateDir ];
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.bookshelf-refresh = lib.mkIf cfg.refresh.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.refresh.startAt;
        Persistent = true;
        RandomizedDelaySec = "20m";
      };
    };

    systemd.services.bookshelf-backup = lib.mkIf cfg.backup.enable {
      description = "Commit the catalogue to its backup repository";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        HOME = cfg.backup.workTree;
        GIT_TERMINAL_PROMPT = "0";
      };
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = lib.getExe backup;
        LoadCredential = lib.mkIf (cfg.backup.remote != null) "ssh-key:${cfg.backup.identityFile}";
        User = cfg.user;
        Group = cfg.user;
        MemoryMax = "128M";
        WorkingDirectory = cfg.backup.workTree;
        ReadWritePaths = [
          cfg.stateDir
          cfg.backup.workTree
        ];
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.bookshelf-backup = lib.mkIf cfg.backup.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.backup.startAt;
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts.${cfg.hostname} = {
        serverAliases = cfg.serverAliases;
        listen =
          map
            (port: {
              addr = cfg.tailnetAddress;
              inherit port;
            })
            (
              lib.unique [
                80
                cfg.tailnetPort
              ]
            );
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          extraConfig = ''
            proxy_set_header Tailscale-User-Login "${cfg.identityLogin}";
            client_max_body_size 4m;
          '';
        };
      };
    };

    networking.firewall.interfaces.${cfg.interface}.allowedTCPPorts = lib.unique [
      80
      cfg.tailnetPort
    ];

    environment.systemPackages = [
      cfg.package
      (lib.mkIf cfg.backup.enable backup)
    ];

    assertions = [
      {
        assertion = cfg.tailnetAddress != "";
        message = "local.bookshelf.tailnetAddress must be this host's tailnet address; an empty listen address would expose the catalogue on every interface.";
      }
      {
        assertion = cfg.identityLogin != "";
        message = "local.bookshelf.identityLogin must be set; the application trusts Tailscale-User-Login and has no other notion of who is asking.";
      }
      {
        assertion = cfg.port >= 1024;
        message = "local.bookshelf.port must stay above 1024; the service runs with no capabilities.";
      }
      {
        assertion = under cfg.stateDir cfg.databasePath;
        message = "local.bookshelf.databasePath must be inside stateDir, the only path the service may write.";
      }
      {
        assertion = !cfg.backup.enable || !under cfg.stateDir cfg.backup.workTree;
        message = "local.bookshelf.backup.workTree must sit outside stateDir, or a backup would be dumped into the thing it is backing up.";
      }
      {
        assertion = cfg.backup.remote == null || lib.hasPrefix "git@" cfg.backup.remote;
        message = "local.bookshelf.backup.remote must be an SSH remote (git@host:owner/repo.git); the push authenticates with a deploy key, not a token.";
      }
      {
        assertion = !cfg.scrapers || cfg.refresh.enable;
        message = "local.bookshelf.scrapers only acts through the refresh job, so enable local.bookshelf.refresh too.";
      }
    ];
  };
}

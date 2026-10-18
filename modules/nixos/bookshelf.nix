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
  }
  // lib.optionalAttrs cfg.solver.enable {
    BOOKSHELF_SOLVER_URL = "http://127.0.0.1:${toString cfg.solver.port}/v1";
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
    # The search% pattern is what excludes them, shadow tables included, so every FTS
    # table in schema.sql has to be named search-something or the dump will not restore.
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

  mdnsNames = lib.optionals cfg.lan.enable cfg.lan.mdnsNames;

  listenAddresses = [ cfg.tailnetAddress ] ++ lib.optional cfg.lan.enable cfg.lan.address;
  listenInterfaces = [ cfg.interface ] ++ lib.optionals cfg.lan.enable cfg.lan.interfaces;

  plainPorts = lib.unique [
    80
    cfg.tailnetPort
  ];
  tlsPorts = [ cfg.tls.port ];

  # The binary cache holds wildcard 443; a per-address listener would shadow it.
  sharedTlsListeners = lib.optionals cfg.tls.enable [
    {
      addr = "0.0.0.0";
      port = 443;
      ssl = true;
    }
    {
      addr = "[::0]";
      port = 443;
      ssl = true;
    }
  ];
  listenPorts = plainPorts ++ lib.optionals cfg.tls.enable tlsPorts;

  listeners =
    lib.concatMap (
      addr:
      map (port: { inherit addr port; }) plainPorts
      ++ lib.optionals cfg.tls.enable (
        map (port: {
          inherit addr port;
          ssl = true;
        }) tlsPorts
      )
    ) listenAddresses
    ++ sharedTlsListeners;

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
  imports = [ ./mdns-aliases.nix ];

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
        "vendor"
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

    tls = {
      enable = lib.mkEnableOption "serving the catalogue over HTTPS";

      certificate = lib.mkOption {
        type = lib.types.path;
        description = "Certificate covering every name and address the catalogue answers on.";
      };

      keySecret = lib.mkOption {
        type = lib.types.str;
        default = "bookshelf-tls-key";
        description = "sops secret holding the certificate's private key.";
      };

      # The node name already belongs to another vhost on 443.
      port = lib.mkOption {
        type = lib.types.port;
        default = 8443;
        description = "Extra HTTPS port, reachable by node name from a device with no hosts file.";
      };
    };

    lan = {
      enable = lib.mkEnableOption "serving the catalogue on the local network too";

      address = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Local-network address to listen on, under the same name as the tailnet.";
      };

      interfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Local interfaces to open the ports on.";
      };

      mdnsNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "bookshelf.local"
          "books.local"
        ];
        description = "Names published over mDNS, for LAN devices with no Tailscale.";
      };

      readOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Refuse anything but GET from the local network, which has no identity.";
      };
    };

    solver = {
      enable = lib.mkEnableOption "a local FlareSolverr, which the shops behind a JS challenge need";

      port = lib.mkOption {
        type = lib.types.port;
        default = 8191;
        description = "Loopback port FlareSolverr answers on.";
      };

      memoryMax = lib.mkOption {
        type = lib.types.str;
        default = "700M";
        description = "Cap on the bundled browser; above half the pi's RAM it takes the host down.";
      };

      memoryHigh = lib.mkOption {
        type = lib.types.str;
        default = "550M";
        description = "Throttle the browser here, so it is slowed rather than killed.";
      };
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

    backfill = {
      enable = lib.mkEnableOption "asking again about entries a source could not answer";

      interval = lib.mkOption {
        type = lib.types.str;
        default = "2h";
        description = "How often one small batch of queued entries is chased.";
      };

      slice = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "Entries chased per pass; the pi's memory sets this, not politeness.";
      };
    };

    works = {
      enable = lib.mkEnableOption "continuous filling out of the works tree";

      interval = lib.mkOption {
        type = lib.types.str;
        default = "20m";
        description = "How often one bounded slice of works enrichment runs.";
      };

      slice = lib.mkOption {
        type = lib.types.int;
        default = 20;
        description = "Works asked about per run; MusicBrainz allows one request a second.";
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

    sops.secrets =
      lib.genAttrs (lib.attrValues cfg.apiKeySecrets) (_: {
        restartUnits = [ "bookshelf.service" ];
      })
      // lib.optionalAttrs cfg.tls.enable {
        ${cfg.tls.keySecret} = {
          sopsFile = ../../secrets/bookshelf-tls-key.pem;
          format = "binary";
          owner = "nginx";
          restartUnits = [ "nginx.service" ];
        };
      };

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

    systemd.services.flaresolverr = lib.mkIf cfg.solver.enable {
      description = "FlareSolverr: clears a JS challenge for the retail resolvers";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        HOST = "127.0.0.1";
        PORT = toString cfg.solver.port;
        LOG_LEVEL = "warning";
        BROWSER_TIMEOUT = "60000";
        # The bundled browser writes a profile under $HOME, which is / without this.
        HOME = "/var/lib/flaresolverr";
        XDG_CONFIG_HOME = "/var/lib/flaresolverr/.config";
        XDG_CACHE_HOME = "/var/lib/flaresolverr/.cache";
      };
      serviceConfig = {
        ExecStart = lib.getExe pkgs.flaresolverr;
        DynamicUser = true;
        StateDirectory = "flaresolverr";
        WorkingDirectory = "/var/lib/flaresolverr";
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStopSec = 20;
        MemoryMax = cfg.solver.memoryMax;
        MemoryHigh = cfg.solver.memoryHigh;
        # Chromium needs an unprivileged user namespace for its own sandbox, so the
        # unit cannot take one away from it.
        PrivateUsers = false;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = false;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
      };
    };

    systemd.services.bookshelf-prices = lib.mkIf cfg.refresh.enable {
      description = "Ask the shops what each edition costs new";
      after = [
        "network-online.target"
        "bookshelf.service"
      ];
      wants = [ "network-online.target" ];
      inherit environment;
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${lib.getExe cfg.package} --refresh-prices --database ${cfg.databasePath}";
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

    systemd.timers.bookshelf-prices = lib.mkIf cfg.refresh.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.refresh.startAt;
        Persistent = true;
        RandomizedDelaySec = "20m";
      };
    };

    local.mdns = {
      address = lib.mkDefault cfg.lan.address;
      names = mdnsNames;
    };

    systemd.services.bookshelf-backfill = lib.mkIf cfg.backfill.enable {
      description = "Ask again about the entries a source could not answer about";
      after = [
        "network-online.target"
        "bookshelf.service"
      ];
      wants = [ "network-online.target" ];
      inherit environment;
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${lib.getExe cfg.package} --backfill --slice ${toString cfg.backfill.slice} --database ${cfg.databasePath}";
        EnvironmentFile = lib.mkIf (cfg.apiKeySecrets != { }) config.sops.templates."bookshelf-env".path;
        User = cfg.user;
        Group = cfg.user;
        MemoryMax = "192M";
        WorkingDirectory = cfg.stateDir;
        ReadWritePaths = [ cfg.stateDir ];
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.bookshelf-backfill = lib.mkIf cfg.backfill.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = cfg.backfill.interval;
        OnUnitInactiveSec = cfg.backfill.interval;
        RandomizedDelaySec = "10m";
      };
    };

    systemd.services.bookshelf-works = lib.mkIf cfg.works.enable {
      description = "Fill out one slice of the works tree";
      after = [
        "network-online.target"
        "bookshelf.service"
      ];
      wants = [ "network-online.target" ];
      inherit environment;
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${lib.getExe cfg.package} --enrich-works --slice ${toString cfg.works.slice} --database ${cfg.databasePath}";
        User = cfg.user;
        Group = cfg.user;
        MemoryMax = "192M";
        WorkingDirectory = cfg.stateDir;
        ReadWritePaths = [ cfg.stateDir ];
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.bookshelf-works = lib.mkIf cfg.works.enable {
      wantedBy = [ "timers.target" ];
      # Relative to the timer starting, not to boot: an activation arms the timer, and
      # OnBootSec would fire the job immediately and colour the switch with its exit code.
      timerConfig = {
        OnActiveSec = cfg.works.interval;
        OnUnitInactiveSec = cfg.works.interval;
        RandomizedDelaySec = "5m";
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

    # An empty value is omitted by nginx and overwrites a client-sent header.
    services.nginx.appendHttpConfig = ''
      map $server_addr $bookshelf_identity {
        ${cfg.tailnetAddress} "${cfg.identityLogin}";
        default "";
      }

      map "$bookshelf_identity:$request_method" $bookshelf_denied {
        "~^:(GET|HEAD)$" 0;
        "~^:"            1;
        default          0;
      }
    '';

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts.${cfg.hostname} = {
        serverAliases = lib.unique (cfg.serverAliases ++ mdnsNames);
        addSSL = cfg.tls.enable;
        sslCertificate = lib.mkIf cfg.tls.enable cfg.tls.certificate;
        sslCertificateKey = lib.mkIf cfg.tls.enable config.sops.secrets.${cfg.tls.keySecret}.path;
        listen = listeners;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          extraConfig = ''
            proxy_set_header Tailscale-User-Login $bookshelf_identity;
            client_max_body_size 4m;
          ''
          + lib.optionalString cfg.lan.readOnly ''
            if ($bookshelf_denied) {
              return 403;
            }
          '';
        };
      };
    };

    networking.firewall.interfaces = lib.genAttrs listenInterfaces (_: {
      allowedTCPPorts = listenPorts;
    });

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
        assertion = !cfg.lan.enable || cfg.lan.address != "";
        message = "local.bookshelf.lan.address must be this host's local-network address; without it the vhost would answer on every interface.";
      }
      {
        assertion = !cfg.lan.enable || cfg.lan.interfaces != [ ];
        message = "local.bookshelf.lan.interfaces must list the local interfaces to open, or the local network cannot reach it.";
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

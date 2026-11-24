# Raspberry Pi 5: always-on server, no VPN, remote build client.

{
  config,
  lib,
  pkgs,
  inputs,
  facts,
  ...
}:

let
  tailnetName = "pi.taild5b88a.ts.net";
  tailnetCertDir = "/var/lib/tailscale-cert";
  tailnetOnly = ''
    allow 100.64.0.0/10;
    allow fd7a:115c:a1e0::/48;
    deny all;
  '';
  httpsListen =
    map
      (addr: {
        inherit addr;
        port = 443;
        ssl = true;
      })
      [
        "0.0.0.0"
        "[::0]"
      ];
  grafanaProxy = {
    proxyPass = "http://127.0.0.1:3000";
    proxyWebsockets = true;
    extraConfig = ''
      proxy_set_header Tailscale-User-Login $grafana_user_login;
      proxy_set_header Tailscale-User-Name $grafana_user_name;
    '';
  };
  apps = [
    {
      name = "Jobs";
      href = "/jobs/";
    }
    {
      name = "Bookshelf";
      href = "/bookshelf/";
    }
    {
      name = "Observatory";
      href = "/observatory/";
    }
    {
      name = "Servers";
      href = "/servers/";
    }
  ];
  landing = pkgs.writeTextDir "index.html" ''
    <!doctype html>
    <html lang="en">
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <title>pi</title>
    <style>
      body { font: 18px/1.4 system-ui, sans-serif; margin: 0 auto; max-width: 28rem; padding: 2rem 1rem; }
      a { display: block; padding: 1rem; margin: .5rem 0; border: 1px solid #8884; border-radius: .6rem; text-decoration: none; color: inherit; font-size: 1.25rem; }
    </style>
    <h1>pi</h1>
    ${lib.concatMapStrings (a: ''<a href="${a.href}">${a.name}</a>'' + "\n") apps}
  '';
in
{
  imports = [
    ./hardware.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/roles/member.nix
    ../../modules/nixos/wifi.nix
    ../../modules/nixos/wake.nix
    ../../modules/nixos/wake-endpoint.nix
    ../../modules/nixos/power.nix
    ../../modules/nixos/server/net-watchdog.nix
    ../../modules/nixos/service-priority.nix
    ../../modules/nixos/flight-recorder.nix
    ../../modules/nixos/storage.nix
    ../../modules/nixos/nas/accounts.nix
    ../../modules/nixos/nas/samba.nix
    ../../modules/nixos/nas/storage.nix
    ../../modules/nixos/nas/index.nix
    ../../modules/nixos/nas/cache.nix
    ../../modules/nixos/nas/attic.nix
    ../../modules/nixos/nas/unlock.nix
    ../../modules/nixos/nas/checkpoints.nix
    ../../modules/nixos/nas/prefetch.nix
    ../../modules/nixos/nas/streams.nix
    ../../modules/nixos/fancontrol.nix
    ../../modules/nixos/gpio-pwm-fan.nix
    ../../modules/nixos/build-client.nix
    ../../modules/nixos/pam-ssh-agent-sudo.nix
    ../../modules/nixos/browser-sync.nix
    inputs.bookshelf.nixosModules.default
    inputs.jobs.nixosModules.pi
    ../../modules/nixos/mdns-aliases.nix
    ./satisfactory.nix
  ];

  networking.hostName = "pi";
  boot.kernelParams = [ "psi=1" ];
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;
  boot.kernelModules = [ "drivetemp" ];
  # auth.proxy auto-assigns Admin, and an empty value overwrites a client-sent header.
  services.nginx.appendHttpConfig = ''
    map $server_addr $grafana_user_login {
      ${facts.pi.tailscale} "MaxCarroll0@github";
      default "";
    }
    map $server_addr $grafana_user_name {
      ${facts.pi.tailscale} "Max";
      default "";
    }
  '';

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts.observatory = {
      serverAliases = [
        "grafana"
        "pi.grafana"
        "observatory.local"
        "grafana.local"
      ];
      listen = [
        {
          addr = facts.pi.tailscale;
          port = 80;
        }
        {
          addr = "192.168.200.81";
          port = 80;
        }
      ];
      locations."= /".return = "302 /observatory/";
      locations."/observatory/" = grafanaProxy;
    };
    virtualHosts.pi-short-http = {
      serverName = "pi";
      serverAliases = [ tailnetName ];
      listen = [
        {
          addr = facts.pi.tailscale;
          port = 80;
        }
        {
          addr = "[::0]";
          port = 80;
        }
      ];
      extraConfig = tailnetOnly;
      locations."/".return = "301 https://${tailnetName}$request_uri";
      locations."~ ^/fleet-history/(api/v1/(query|query_range|series))$" = {
        proxyPass = "http://127.0.0.1:9091/$1$is_args$args";
        extraConfig = "limit_except GET { deny all; }";
      };
    };
    virtualHosts.pi-short = {
      serverName = "pi";
      listen = httpsListen;
      onlySSL = true;
      sslCertificate = ../../keys/bookshelf.crt;
      sslCertificateKey = config.sops.secrets.bookshelf-tls-key.path;
      extraConfig = tailnetOnly;
      locations."/".return = "301 https://${tailnetName}$request_uri";
    };
    virtualHosts.pi = {
      serverName = tailnetName;
      listen = httpsListen;
      onlySSL = true;
      sslCertificate = "${tailnetCertDir}/cert.pem";
      sslCertificateKey = "${tailnetCertDir}/key.pem";
      extraConfig = tailnetOnly;
      locations."= /" = {
        root = landing;
        tryFiles = "/index.html =404";
        extraConfig = ''
          default_type text/html;
          add_header Cache-Control "no-cache";
        '';
      };
      locations."/observatory/" = grafanaProxy;
      locations."= /bookshelf".return = "301 /bookshelf/";
      locations."/bookshelf/" = {
        proxyPass = "http://127.0.0.1:${toString config.local.bookshelf.port}/";
        extraConfig = ''
          proxy_set_header Tailscale-User-Login $bookshelf_identity;
          proxy_set_header Bookshelf-Writable-At $bookshelf_writable_at;
          proxy_set_header Accept-Encoding "";
          proxy_buffering off;
          proxy_redirect / /bookshelf/;
          client_max_body_size 4m;
          sub_filter_once off;
          sub_filter_types application/javascript text/javascript text/event-stream;
          sub_filter 'href="/' 'href="/bookshelf/';
          sub_filter 'action="/' 'action="/bookshelf/';
          sub_filter 'src="/' 'src="/bookshelf/';
          sub_filter 'data-tree="/' 'data-tree="/bookshelf/';
          sub_filter "'/lookup" "'/bookshelf/lookup";
          sub_filter '`/' '`/bookshelf/';
        '';
      };
      locations."= /servers".return = "301 /servers/";
      locations."/servers/" = {
        proxyPass = "http://${facts.pi.tailscale}:7780/";
        recommendedProxySettings = false;
        extraConfig = ''
          proxy_set_header X-Forwarded-For $remote_addr;
          proxy_set_header Accept-Encoding "";
          proxy_redirect / /servers/;
          sub_filter_once off;
          sub_filter '"/api/' '"/servers/api/';
          sub_filter '"/minecraft-mods.zip' '"/servers/minecraft-mods.zip';
        '';
      };
    };
  };
  systemd.services.nginx = {
    after = [
      "tailscaled.service"
      "tailscale-cert.service"
    ];
    wants = [
      "tailscaled.service"
      "tailscale-cert.service"
    ];
  };
  systemd.services.tailscale-cert = {
    description = "Tailscale certificate for ${tailnetName}";
    after = [
      "tailscaled.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    path = [
      config.services.tailscale.package
      pkgs.coreutils
      pkgs.systemd
    ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "3min";
      StateDirectory = "tailscale-cert";
      StateDirectoryMode = "0750";
      Group = "nginx";
    };
    script = ''
      dir=${tailnetCertDir}
      if timeout 120 tailscale cert --cert-file "$dir/cert.new" --key-file "$dir/key.new" ${tailnetName}; then
        mv "$dir/cert.new" "$dir/cert.pem"
        mv "$dir/key.new" "$dir/key.pem"
      elif [ ! -s "$dir/cert.pem" ]; then
        cp ${../../keys/bookshelf.crt} "$dir/cert.pem"
        cp ${config.sops.secrets.bookshelf-tls-key.path} "$dir/key.pem"
      fi
      chmod 0640 "$dir/cert.pem" "$dir/key.pem"
      if systemctl is-active --quiet nginx; then systemctl reload --no-block nginx; fi
    '';
  };
  systemd.timers.tailscale-cert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
  # end0 and wld0 on one subnet break interface-scoped matching, so open both.
  networking.firewall.interfaces = {
    tailscale0.allowedTCPPorts = [ 80 ];
    wld0.allowedTCPPorts = [ 80 ];
    end0.allowedTCPPorts = [ 80 ];
  };

  # First server block on an address is nginx's default; the catalogue now shares it.
  services.nginx.virtualHosts.observatory.default = true;

  swapDevices = lib.mkForce [
    {
      device = "/swapfile";
      size = 4 * 1024;
      randomEncryption.enable = true;
    }
  ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100;
  };

  local.wifi = {
    ssid = "Gigaclear_FA8E";
    pskSecret = "wifi-psk";
    fallbacks = [
      {
        ssid = "VM5077073";
        pskSecret = "wifi-psk-vm5077073";
      }
    ];
  };

  local.disk.ledger.enable = false;

  local.wake.peers.desktopnew.timeoutSeconds = 120;
  local.wakeEndpoint.peer = "desktopnew";

  local.server.ssh = {
    lanInterfaces = [
      "wld0"
      "end0"
    ];
    allowLanTCPPorts = [
      80
      8080
      8443
    ];
  };

  users.users.max.openssh.authorizedKeys.keyFiles = [
    ../../keys/max-desktopnew.pub
  ];

  local.browserSync.server = true;

  system.autoUpgrade.enable = true;
  local.upgrade.rebootWhenNeeded = "Sun *-*-* 05:00:00";

  local.build.client = {
    enable = true;
    builders.laptop = {
      user = "nixremote";
      port = 2222;
      systems = [ "aarch64-linux" ];
      maxJobs = 8;
      speedFactor = 4;
    };
    builders.desktopnew = {
      user = "nixremote";
      port = 2222;
      publicHostKey = "AAAAC3NzaC1lZDI1NTE5AAAAIEhlS3Kx37nOhE6nAnkXgoHU3JwtFLmT1mLbFLcmLXl8";
      systems = [ "aarch64-linux" ];
      maxJobs = 8;
      speedFactor = 20;
    };
  };

  local.monitoring = {
    exporter.scrapeCadenceOverrides.drive-temperatures = {
      match = "^target[0-9]+:0:0_";
      interval = "1m";
      onlyWhenActive = true;
    };
    piFirmware.enable = true;
    grafana.domain = "pi";
    grafana.path = "/observatory/";
    smart.selfTest.enable = true;
    server.enable = true;
    grafana.enable = true;
    targets = {
      desktopnew = "${facts.desktopnew.tailscale}:9100";
      laptop = "${facts.laptop.tailscale}:9100";
    };
    sensorNames = {
      "cpu_thermal:temp1" = "SoC";
      "drivetemp:temp1" = "HDD";
      "pwmfan:fan1" = "Active Cooler";
    };
    totalPower.tariffPencePerKwh = 20.88;

    power = {
      enable = true;
      supply = {
        ratedWatts = 60;
        peakEfficiency = 0.88;
        peakLoadRatio = 0.55;
        curvature = 0.7;
        idleWatts = 0.3;
      };
      pmicEfficiency = 0.87;
      ram.modelled = false;
      fixedComponents."X1009 SATA controller" = 1.8;
      fans.hdd-bay.constantWatts = 0.35;
      fans.active-cooler = {
        chip = "pwmfan";
        sensor = "fan1";
        maxRpm = 7000;
        wattsAtMaxRpm = 0.55;
      };
      disks.sda = {
        standbyWatts = 0.3;
        idleWatts = 0.6;
        activeWatts = 1.8;
      };
    };
  };

  local.nas = {
    enable = true;
    dataRoot = "/srv/nas";
    smb.enable = true;
    cacheServer.enable = true;
    cache.enable = true;
    index.enable = true;
    accounts.nastest = {
      uid = 3000;
      description = "NAS pipeline test account";
    };
    accounts.max = {
      systemUser = true;
      description = "Max";
      tailscaleLogin = "MaxCarroll0@github";
    };
    storage = {
      enable = true;
      parityFsType = "btrfs";
      dataDisks = {
        disk1 = {
          device = "/dev/disk/by-uuid/a9041494-846e-49ab-be81-4bda1523f56c";
          fsType = "nilfs2";
        };
        disk2 = {
          device = "/dev/disk/by-uuid/4627a0ca-4bbc-4ea1-954f-388f8415c94c";
          fsType = "nilfs2";
        };
        disk3 = {
          device = "/dev/disk/by-uuid/b1a560af-b549-4f77-a36c-3f4b74e7c67e";
          fsType = "nilfs2";
        };
      };
    };
    unlock = {
      server = true;
      parityDevice = "/dev/disk/by-uuid/48be9161-8f27-4b53-94f7-a7aa67bd8f53";
    };
    checkpoints.enable = true;
    prefetch.enable = true;
    streams.minecraft = {
      branch = "disk1";
      port = 8020;
      allowFrom = [
        facts.mc-server.tailnetAddress
        facts.desktopnew.tailscale
      ];
    };
    streams.satisfactory = {
      branch = "disk1";
      port = 8021;
      allowFrom = [ facts.desktopnew.tailscale ];
    };
  };

  local.power = {
    instrument = true;
    idle.optimise = false;
    oopsPanic = false;
  };

  powerManagement.cpuFreqGovernor = "schedutil";

  # systemd-shutdown pings the watchdog while D-state processes block it; only skipping it bounds a wedged shutdown.
  systemd.targets = lib.genAttrs [ "reboot" "poweroff" "halt" ] (target: {
    unitConfig = {
      JobTimeoutSec = "2min";
      JobTimeoutAction = "${target}-immediate";
    };
  });
  systemd.settings.Manager.RebootWatchdogSec = lib.mkForce "90s";

  environment.systemPackages = [ pkgs.raspberrypi-eeprom ];

  nix.settings = {
    min-free = 2 * 1024 * 1024 * 1024;
    max-free = 2 * 1024 * 1024 * 1024 + 512 * 1024 * 1024;
    auto-optimise-store = true;
  };
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTRS{idVendor}=="174c", ATTRS{idProduct}=="55aa", ATTR{queue/rotational}="0", ATTR{queue/read_ahead_kb}="128"
  '';

  system.stateVersion = lib.mkForce "26.05";

  local.server.netWatchdog.enable = true;

  local.flightRecorder.enable = true;

  local.storage.spinDownRotational = {
    enable = true;
    apmLevel = 254;
    idleMinutes = 60;
  };

  local.mdns.names = [
    "observatory.local"
    "grafana.local"
  ];

  local.jobs.web = {
    enable = true;
    package = inputs.jobs.packages.x86_64-linux.web;
    virtualHost = "pi";
  };

  local.bookshelf = {
    enable = true;
    tailnetAddress = facts.pi.tailscale;
    identityLogin = "MaxCarroll0@github";
    refresh.enable = true;
    refresh.usedSlice = 120;
    compsProviders = [
      "ebay"
      "abebooks"
      "worldofbooks"
      "amazon"
    ];
    scrapers = true;
    works.enable = true;
    backfill.enable = true;
    audit.enable = true;
    backup = {
      enable = true;
      remote = "git@github.com:MaxCarroll0/bookshelf.git";
      branch = "catalogue-data";
    };
    solver.enable = true;
    tls = {
      enable = true;
      certificate = ../../keys/bookshelf.crt;
      keyFile = ../../secrets/bookshelf-tls-key.pem;
    };
    lan = {
      enable = true;
      readOnly = true;
      address = "192.168.200.81";
      interfaces = [
        "wld0"
        "end0"
      ];
    };
    apiKeySecrets = {
      BOOKSHELF_GOOGLE_BOOKS_KEY = "bookshelf-google-books-key";
      BOOKSHELF_EBAY_CLIENT_ID = "bookshelf-ebay-client-id";
      BOOKSHELF_EBAY_CLIENT_SECRET = "bookshelf-ebay-client-secret";
    };
  };

  local.servicePriority = {
    enable = true;
    swappiness = 150;
    essential = {
      "tailscaled.service" = "48M";
      "sshd.service" = "8M";
      "nginx.service" = "16M";
    };
    critical = {
      "grafana.service" = "192M";
      "systemd-journald.service" = "32M";
    };
    throttle = {
      "victoriametrics.service" = "256M";
      "victoriametrics-history.service" = "128M";
      "bookshelf.service" = "96M";
    };
  };

  systemd.services.grafana.serviceConfig.MemorySwapMax = "192M";

  services.victoriametrics.extraOptions = [
    "-memory.allowedBytes=64MiB"
    "-cacheExpireDuration=5m"
    "-search.maxConcurrentRequests=2"
  ];
  systemd.services.victoriametrics.environment.GOMEMLIMIT = "200MiB";

  # false for 3 pin, true for 4 pin PWM
  local.gpioPwmFan = {
    enable = false;
    failsafeUnits = [ "fan2go.service" ];
  };

  local.fancontrol = {
    enable = false;
    configFile = ./fan2go.yaml;
  };
}

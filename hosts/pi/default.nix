# Raspberry Pi 5: always-on server, no VPN, remote build client.

{ lib, pkgs, ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/wifi.nix
    ../../modules/nixos/wake.nix
    ../../modules/nixos/power.nix
    ../../modules/nixos/monitoring
    ../../modules/nixos/server/ssh.nix
    ../../modules/nixos/server/tailscale.nix
    ../../modules/nixos/net-watchdog.nix
    ../../modules/nixos/service-priority.nix
    ../../modules/nixos/storage.nix
    ../../modules/nixos/nas/accounts.nix
    ../../modules/nixos/nas/samba.nix
    ../../modules/nixos/nas/storage.nix
    ../../modules/nixos/nas/index.nix
    ../../modules/nixos/nas/cache.nix
    ../../modules/nixos/nas/unlock.nix
    ../../modules/nixos/nas/checkpoints.nix
    ../../modules/nixos/nas/versions.nix
    ../../modules/nixos/nas/prefetch.nix
    ../../modules/nixos/fancontrol.nix
    ../../modules/nixos/gpio-pwm-fan.nix
    ../../modules/nixos/build-client.nix
    ../../modules/nixos/pam-ssh-agent-sudo.nix
  ];

  networking.hostName = "pi";
  boot.kernelParams = [ "psi=1" ];
  boot.kernelModules = [ "drivetemp" ];
  networking.hosts."100.117.13.66" = [
    "observatory"
    "grafana"
    "pi.grafana"
  ];

  # Grafana itself binds to loopback and no longer allows anonymous access, so reaching this
  # vhost gets a login form rather than an admin session. Per-user Tailscale identity via
  # auth.proxy needs `tailscale serve`, which needs HTTPS enabled for the tailnet.
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts.observatory.locations."/" = {
      proxyPass = "http://127.0.0.1:3000";
      proxyWebsockets = true;
    };
  };
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 ];

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

  local.wake.peers.desktopnew = {
    mac = "b4:2e:99:92:d6:18";
    broadcast = "192.168.0.255";
    address = "192.168.0.161";
    timeoutSeconds = 90;
  };

  local.server.ssh = {
    enable = true;
    port = 2222;
    allowUsers = [ "max" ];
    lanInterfaces = [
      "wld0"
      "end0"
    ];
  };

  local.server.tailscale = {
    enable = true;
    ssh = true;
    authKeySecret = "tailscale-auth-key";
  };

  users.users.max.openssh.authorizedKeys.keyFiles = [ ../../keys/max.pub ];

  local.build.client = {
    enable = true;
    builders.laptop = {
      user = "max";
      port = 22;
      tailscaleSsh = true;
      systems = [ "aarch64-linux" ];
      maxJobs = 8;
      speedFactor = 4;
    };
    builders.desktopnew = {
      user = "max";
      port = 22;
      tailscaleSsh = true;
      systems = [ "aarch64-linux" ];
      maxJobs = 8;
      speedFactor = 20;
    };
  };

  local.monitoring = {
    exporter.enable = true;
    exporter.scrapeCadenceOverrides.drive-temperatures = {
      match = "^target[0-9]+:0:0_";
      interval = "1m";
      onlyWhenActive = true;
    };
    piFirmware.enable = true;
    smart.enable = true;
    smart.selfTest.enable = true;
    server.enable = true;
    grafana.enable = true;
    userReadable = true;
    telemetry.journalGateway.enable = true;
    targets = {
      desktopnew = "100.106.140.88:9100";
      laptop = "100.112.109.20:9100";
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
      boardWatts = 0.5;
      peripheralsWatts = 1.8;
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
          device = "/dev/sdd";
          fsType = "nilfs2";
        };
        disk2 = {
          device = "/dev/sdb";
          fsType = "nilfs2";
        };
      };
    };
    unlock = {
      server = true;
      parityDevice = "/dev/sdc";
    };
    checkpoints.enable = true;
    versions.enable = true;
    prefetch.enable = true;
  };

  local.power = {
    instrument = true;
    idle.optimise = false;
  };

  powerManagement.cpuFreqGovernor = "powersave";

  environment.systemPackages = [ pkgs.raspberrypi-eeprom ];

  nix.settings = {
    min-free = 2 * 1024 * 1024 * 1024;
    max-free = 5 * 1024 * 1024 * 1024;
    auto-optimise-store = true;
  };
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTRS{idVendor}=="174c", ATTRS{idProduct}=="55aa", ATTR{queue/rotational}="0", ATTR{queue/read_ahead_kb}="128"
  '';

  system.stateVersion = lib.mkForce "26.05";

  local.server.netWatchdog.enable = true;

  local.storage.spinDownRotational = {
    enable = true;
    apmLevel = 254;
    idleMinutes = 60;
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
    };
  };

  systemd.services.grafana.serviceConfig.MemorySwapMax = "192M";

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

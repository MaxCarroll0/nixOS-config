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

  # Grafana remains on its private service port. This tailnet-only proxy gives
  # it a memorable, port-free browser address: http://observatory.
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

  local.wake.peers.desktop_new = {
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
    builders.desktop_new = {
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
    piFirmware.enable = true;
    server.enable = true;
    grafana.enable = true;
    userReadable = true;
    telemetry = {
      collector.enable = true;
      server.enable = true;
    };
    targets = {
      desktop_new = "100.106.140.88:9100";
      laptop = "100.112.109.20:9100";
    };
    sensorNames = {
      "cpu_thermal:temp1" = "SoC";
      "drivetemp:temp1" = "HDD";
      "pwmfan:fan1" = "Active Cooler";
    };
    totalPower = {
      wallEstimateWatts = 6;
      baselineWatts = 6;
      psuEfficiency = 1;
      tariffPencePerKwh = 20.88;
    };
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

  # Writing rotational makes the kernel recompute readahead, so it must come first
  # or read_ahead_kb is reset to the device maximum.
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTRS{idVendor}=="174c", ATTRS{idProduct}=="55aa", ATTR{queue/rotational}="0", ATTR{queue/read_ahead_kb}="128"
  '';

  system.stateVersion = lib.mkForce "26.05";

  local.server.netWatchdog.enable = true;

  local.servicePriority = {
    enable = true;
    swappiness = 60;
    essential = {
      "tailscaled.service" = "48M";
      "sshd.service" = "16M";
      "nginx.service" = "24M";
    };
    bulk = [ "prometheus-rule-backfill.service" ];
    critical = {
      "grafana.service" = "128M";
    };
  };

  local.monitoring.backfill = {
    enable = true;
    intervalMinutes = 60;
    cpuQuotaPercent = 20;
    memoryMax = "192M";
    evalIntervalSeconds = 30;
    windowMinutes = 180;
  };

  systemd.services.grafana.serviceConfig.MemorySwapMax = 0;
  systemd.services.prometheus-rule-backfill = {
    after = [ "grafana.service" ];
    serviceConfig.ExecCondition = "${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 5 http://127.0.0.1:3000/api/health";
  };
  systemd.timers.prometheus-rule-backfill.timerConfig.OnBootSec = lib.mkForce "15m";

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

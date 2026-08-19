# Shared by every AMD desktop host: workstation, remote builder, SSH host, web origin.

{ lib, pkgs, ... }:

{
  imports = [
    ../modules/nixos/common.nix
    ../modules/nixos/desktop-env.nix
    ../modules/nixos/vpn.nix
    ../modules/nixos/wake.nix
    ../modules/nixos/power.nix
    ../modules/nixos/monitoring
    ../modules/nixos/fancontrol.nix
    ../modules/nixos/storage.nix
    ../modules/nixos/wifi.nix
    ../modules/nixos/server/ssh.nix
    ../modules/nixos/server/tailscale.nix
    ../modules/nixos/server/build-host.nix
    ../modules/nixos/server/web.nix
    ../modules/nixos/pam-ssh-agent-sudo.nix
  ];

  networking.hosts."100.117.13.66" = [
    "observatory"
    "grafana"
    "pi.grafana"
  ];

  local.vpn.selection = {
    countries = [ "UK" ];
    rotateEvery = "6h";
  };

  boot.loader.timeout = 0;

  systemd.services.tailscaled.after = lib.mkForce [ "sops-install-secrets.service" ];

  swapDevices = lib.mkForce [
    {
      device = "/swapfile";
      size = 32 * 1024;
      randomEncryption.enable = true;
    }
  ];

  local.server.ssh = {
    enable = true;
    port = 2222;
    allowUsers = [ "max" ];
  };
  local.server.tailscale = {
    enable = true;
    ssh = true;
    authKeySecret = "tailscale-auth-key";
  };

  users.users.max.openssh.authorizedKeys.keyFiles = [ ../keys/max.pub ];

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

  # Enable once the laptop's root key exists; see TODO.md.
  local.build.host = {
    enable = false;
    authorizedKeys = [ ];
    emulatedSystems = [ "aarch64-linux" ];
  };

  local.web.public = {
    enable = false;
    tunnelId = "";
    hostnames = { };
  };

  local.storage = {
    spinDownRotational.enable = true;
    lazyMounts = { };
  };

  local.fancontrol.enable = lib.mkDefault false;

  systemd.services.schedutil-rate-limit = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.writeShellScript "schedutil-rate-limit" ''
        echo 50000 > /sys/devices/system/cpu/cpufreq/schedutil/rate_limit_us
      ''}";
    };
  };

  local.monitoring = {
    exporter.enable = true;
    smart.enable = true;
    server.enable = false;
    grafana.enable = false;
    userReadable = true;

    exporter.scrapeCadenceOverrides.nvme = {
      match = "^nvme_nvme0$";
      interval = "5s";
    };

    telemetry.journalGateway.enable = true;

    targets = {
      pi = "100.117.13.66:9100";
      laptop = "100.112.109.20:9100";
    };

    totalPower.tariffPencePerKwh = 20.88;

    power = {
      enable = true;
      supply = {
        ratedWatts = 650;
        peakEfficiency = 0.9;
        peakLoadRatio = 0.45;
        curvature = 0.6;
        idleWatts = 1.5;
      };
      ram = {
        wattsPerGiB = 0.11;
        activeWattsPerGiB = 0.06;
      };
      gpu = {
        boardFactor = 1.13;
        overheadWatts = 7;
      };
      boardWatts = 12;
      peripheralsWatts = 2;
      fans.cpu = {
        chip = "it8792";
        sensor = "fan1";
        maxRpm = 2200;
        wattsAtMaxRpm = 2.4;
      };
      fans.chassis.constantWatts = 2;
      fans.gpu = {
        chip = "amdgpu";
        sensor = "fan1";
        maxRpm = 2400;
        wattsAtMaxRpm = 2.5;
      };
    };

    sensorNames = {
      "k10temp:temp1" = "CPU Tctl";
      "k10temp:temp3" = "CPU CCD1";
      "k10temp:temp4" = "CPU CCD2";
      "amdgpu:temp1" = "GPU edge";
      "amdgpu:fan1" = "GPU fan";
      "amdgpu:power1" = "GPU board power";
      "amdgpu:in0" = "GPU core";
      "amdgpu:pwm1" = "GPU fan duty";
      "nvme:temp1" = "NVMe";
      "acpitz:temp1" = "Ambient";
    };
  };

  local.power = {
    instrument = true;
    idle.optimise = true;
    idle.policy = "autosuspend";
    idle.autosuspend.idleMinutes = 30;
    idle.autosuspend.powerOffAfterHours = 6;
    idle.autosuspend.watchPorts = [
      22
      2222
    ];
  };
}

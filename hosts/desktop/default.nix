# AMD desktop: workstation plus remote builder, SSH host, and web origin.

{ lib, pkgs, ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-env.nix
    ../../modules/nixos/vpn.nix
    ../../modules/nixos/wake.nix
    ../../modules/nixos/power.nix
    ../../modules/nixos/fancontrol.nix
    ../../modules/nixos/storage.nix
    ../../modules/nixos/wifi.nix
    ../../modules/nixos/server/ssh.nix
    ../../modules/nixos/server/tailscale.nix
    ../../modules/nixos/server/build-host.nix
    ../../modules/nixos/server/web.nix
    ../../modules/nixos/pam-ssh-agent-sudo.nix
  ];

  networking.hostName = "desktop";

  local.vpn = {
    configs.nl = "proton-wg-2";
    primary = "nl";
  };

  swapDevices = lib.mkForce [
    {
      device = "/swapfile";
      size = 32 * 1024;
    }
  ];

  local.server.ssh = {
    enable = true;
    port = 2222;
    allowUsers = [ "max" ];
    lanInterfaces = [
      "enp6s0"
      "wlp5s0"
    ];
  };
  local.server.tailscale = {
    enable = true;
    ssh = true;
    authKeySecret = "tailscale-auth-key";
  };

  users.users.max.openssh.authorizedKeys.keyFiles = [ ../../keys/max.pub ];

  local.wifi = {
    ssid = "Gigaclear_FA8E";
    pskSecret = "wifi-psk";
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

  # it87 can't probe this board's Super I/O chip and gigabyte_wmi has no pwm control; leave off until a fix turns up.
  local.fancontrol.enable = false;

  systemd.services.schedutil-rate-limit = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${
        pkgs.writeShellScript "schedutil-rate-limit" ''
          echo 50000 > /sys/devices/system/cpu/cpufreq/schedutil/rate_limit_us
        ''
      }";
    };
  };

  services.prometheus.scrapeConfigs = [
    {
      job_name = "node-pi";
      static_configs = [
        {
          targets = [ "100.117.13.66:9100" ];
          labels.instance = "pi";
        }
      ];
    }
  ];

  local.power = {
    monitoring.enable = true;
    monitoring.userReadable = true;
    monitoring.grafana = true;
    idle.optimise = true;
    idle.policy = "autosuspend";
    idle.autosuspend.idleMinutes = 30;
    idle.autosuspend.powerOffAfterHours = 6;
    idle.autosuspend.watchPorts = [
      22
      2222
    ];
    wakeOnLan = {
      interface = "enp6s0";
      mac = "70:85:c2:54:c6:89";
    };
  };
}

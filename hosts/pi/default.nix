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
    ../../modules/nixos/build-client.nix
    ../../modules/nixos/pam-ssh-agent-sudo.nix
  ];

  networking.hostName = "pi";

  swapDevices = lib.mkForce [
    {
      device = "/swapfile";
      size = 4 * 1024;
    }
  ];

  local.wifi = {
    ssid = "Gigaclear_FA8E";
    pskSecret = "wifi-psk";
  };

  local.wake.peers.desktop_new = {
    mac = "b4:2e:99:92:d6:18";
    broadcast = "192.168.200.255";
    address = "192.168.200.204";
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
    userReadable = true;
    sensorNames = {
      "cpu_thermal:temp1" = "SoC";
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

  system.stateVersion = lib.mkForce "26.05";

  local.server.netWatchdog.enable = true;
}

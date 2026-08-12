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
  boot.kernelParams = [ "psi=1" ];
  networking.hosts."100.117.13.66" = [ "observatory" "grafana" "pi.grafana" ];

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

  system.stateVersion = lib.mkForce "26.05";

  local.server.netWatchdog.enable = true;
}

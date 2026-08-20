# ThinkPad: workstation only, offloads builds to the desktop.

{ ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-env.nix
    ../../modules/nixos/vpn.nix
    ../../modules/nixos/wake.nix
    ../../modules/nixos/monitoring
    ../../modules/nixos/build-client.nix
    ../../modules/nixos/torrent.nix
    ../../modules/nixos/server/ssh.nix
    ../../modules/nixos/server/tailscale.nix
    ../../modules/nixos/server/build-host.nix
    ../../modules/nixos/pam-ssh-agent-sudo.nix
    ../../modules/nixos/nas/accounts.nix
    ../../modules/nixos/nas/unlock.nix
  ];

  networking.hostName = "laptop";

  local.nas.unlock.client = true;
  sops.secrets."nas-luks-key" = {
    sopsFile = ../../secrets/nas.yaml;
    owner = "max";
    mode = "0400";
  };

  networking.hosts."100.117.13.66" = [
    "observatory"
    "grafana"
    "pi.grafana"
  ];

  services.thermald.enable = true;

  local.monitoring = {
    exporter.enable = true;
    laptopTelemetry.enable = true;
    smart.enable = true;
    userReadable = true;
    telemetry.journalGateway.enable = true;
    sensorNames = {
      "coretemp:temp1" = "CPU package";
      "nvme:temp1" = "NVMe";
      "acpitz:temp1" = "Ambient";
    };

    power = {
      enable = true;
      supply = {
        ratedWatts = 65;
        peakEfficiency = 0.9;
        peakLoadRatio = 0.5;
        curvature = 0.7;
        idleWatts = 0.2;
      };
      ram.modelled = false;
      backlightMaxWatts = 6;
      boardWatts = 1.5;
      peripheralsWatts = 0.8;
      fans.chassis.constantWatts = 0.3;
    };
  };

  local.vpn.selection = {
    countries = [ "UK" ];
    rotateEvery = "6h";
  };

  boot.initrd.luks.devices.vault.device = "/dev/disk/by-uuid/13a8f54b-94ee-46d2-a139-d44eeac71cdc";
  fileSystems."/vault" = {
    device = "/dev/mapper/vault";
    fsType = "ext4";
  };

  local.torrent = {
    enable = true;
    downloadDir = "/vault/torrents";
  };
  systemd.services.transmission.bindsTo = [ "vault.mount" ];

  services.earlyoom = {
    freeMemThreshold = 15;
    freeSwapThreshold = 25;
    extraArgs = [
      "--prefer"
      "^firefox$"
      "--avoid"
      "^(sshd?|systemd|kwin_wayland|Hyprland|plasmashell)$"
    ];
  };

  # Enabling sshd is also what generates /etc/ssh/ssh_host_ed25519_key, which
  # sops.age.sshKeyPaths picks up by default.
  local.server.ssh = {
    enable = true;
    allowUsers = [ "max" ];
  };
  local.server.tailscale = {
    enable = true;
    ssh = true;
    authKeySecret = "tailscale-auth-key";
  };

  local.wake.peers.desktopnew = {
    mac = "b4:2e:99:92:d6:18";
    broadcast = "192.168.0.255";
    address = "192.168.0.161";
    timeoutSeconds = 90;
  };
  users.users.max.openssh.authorizedKeys.keyFiles = [ ../../keys/max.pub ];

  users.users.max.linger = true;

  boot.loader.grub.extraEntries = /* bash */ ''
    menuentry "Ubuntu iso" {
      insmod ext2
      set isofile="/ubuntu/ubuntu.iso"
      loopback loop (hd0,5)$isofile
      linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=$isofile quiet noeject noprompt splash
      initrd (loop)/casper/initrd
    }
  '';

  system.autoUpgrade.enable = true;

  local.build.host.emulatedSystems = [ "aarch64-linux" ];

  local.build.client = {
    enable = true;
    builders.desktopnew = {
      wakePeer = "desktopnew";
      user = "max";
      port = 22;
      tailscaleSsh = true;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      maxJobs = 8;
      speedFactor = 20;
    };
  };
}

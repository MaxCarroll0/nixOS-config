# ThinkPad: workstation only, offloads builds to the desktop.

{ lib, ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/containers.nix
    ../../modules/nixos/desktop-env.nix
    ../../modules/nixos/vpn.nix
    ../../modules/nixos/wake.nix
    ../../modules/nixos/monitoring
    ../../modules/nixos/build-client.nix
    ../../modules/nixos/torrent.nix
    ../../modules/nixos/storage.nix
    ../../modules/nixos/server/ssh.nix
    ../../modules/nixos/server/tailscale.nix
    ../../modules/nixos/server/build-host.nix
    ../../modules/nixos/pam-ssh-agent-sudo.nix
    ../../modules/nixos/nas/accounts.nix
    ../../modules/nixos/nas/unlock.nix
    ../../modules/nixos/nas/attic-client.nix
    ../../modules/nixos/nas/client.nix
  ];

  networking.hostName = "laptop";

  local.nas.unlock.client = true;
  local.atticClient = {
    enable = true;
    publicKey = lib.removeSuffix "\n" (builtins.readFile ../../keys/attic-public-key);
  };
  local.nasClient.enable = true;
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

  local.storage.luksVaults.vault = {
    device = "/dev/disk/by-uuid/13a8f54b-94ee-46d2-a139-d44eeac71cdc";
    mountPoint = "/vault";
    units = [ "transmission.service" ];
  };

  local.torrent = {
    enable = true;
    downloadDir = "/vault/torrents";
  };
  systemd.services.transmission = {
    wantedBy = lib.mkForce [ ];
    unitConfig.ConditionPathIsMountPoint = "/vault";
  };
  systemd.services.transmission-setup = {
    wantedBy = lib.mkForce [ ];
    unitConfig.ConditionPathIsMountPoint = "/vault";
    unitConfig.RequiresMountsFor = lib.mkForce [ ];
  };

  services.earlyoom = {
    freeMemThreshold = 15;
    freeSwapThreshold = 25;
    extraArgs = [
      "--prefer"
      "^chromium$"
      "--avoid"
      "^(sshd?|systemd|kwin_wayland|Hyprland|plasmashell)$"
    ];
  };

  # Enabling sshd is also what generates /etc/ssh/ssh_host_ed25519_key, which
  # sops.age.sshKeyPaths picks up by default.
  local.server.ssh = {
    enable = true;
    allowUsers = [ "max" ];
    lanInterfaces = [ "wlo1" "enp0s31f6" ];
  };
  local.server.tailscale = {
    enable = true;
    ssh = true;
    authKeySecret = "tailscale-auth-key";
  };

  local.wake.peers.desktopnew = {
    mac = "b4:2e:99:92:d6:18";
    timeoutSeconds = 120;
  };
  users.users.max.openssh.authorizedKeys.keyFiles = [
    ../../keys/max.pub
    ../../keys/max-desktopnew.pub
  ];

  users.users.max.linger = true;

  boot.loader.grub.configurationLimit = 15;

  boot.loader.grub.extraEntries = /* bash */ ''
    menuentry "Ubuntu iso" {
      insmod ext2
      insmod loopback
      insmod iso9660
      search --no-floppy --fs-uuid --set=root dbb5c694-3987-4403-a523-ace9f7d16c97
      set isofile="/ubuntu.iso"
      loopback loop $isofile
      linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=$isofile quiet noeject noprompt splash
      initrd (loop)/casper/initrd
    }
  '';

  system.autoUpgrade.enable = true;

  local.build.host = {
    enable = true;
    authorizedKeys = [ (builtins.readFile ../../keys/max.pub) ];
    emulatedSystems = [ "aarch64-linux" ];
  };

  local.build.client = {
    enable = true;
    builders.desktopnew = {
      wakePeer = "desktopnew";
      user = "nixremote";
      port = 2222;
      sshKey = "/home/max/.ssh/id_ed25519";
      publicHostKey = "AAAAC3NzaC1lZDI1NTE5AAAAIEhlS3Kx37nOhE6nAnkXgoHU3JwtFLmT1mLbFLcmLXl8";
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      maxJobs = 8;
      speedFactor = 20;
    };
  };
}

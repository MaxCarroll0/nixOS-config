# Libvirt host for damien-fedora, a Fedora guest isolated from the LAN and tailnet.

{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  nixvirt = inputs.NixVirt;

  domainName = "damien-fedora";
  imageDir = "/var/lib/libvirt/images";
  diskPath = "${imageDir}/${domainName}.qcow2";
  seedPath = "${imageDir}/${domainName}-seed.iso";
  diskSize = "128G";
  bridge = "virbr0";

  fedoraCloud = pkgs.fetchurl {
    url = "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2";
    hash = "sha256:28680fe5b371a5a82ebf43a31926e086a168e59949d03969c5093e7071f90b7f";
  };

  metaData = pkgs.writeText "${domainName}-meta-data" ''
    instance-id: ${domainName}-root
    local-hostname: ${domainName}
  '';

  userData = pkgs.writeText "${domainName}-user-data" ''
    #cloud-config
    users: []
    disable_root: false
    ssh_pwauth: true
    write_files:
      - path: /etc/sysconfig/qemu-ga
        content: |
          FILTER_RPC_ARGS=""
      - path: /etc/ssh/sshd_config.d/01-root.conf
        content: |
          PermitRootLogin yes
          PasswordAuthentication yes
    packages:
      - qemu-guest-agent
      - policycoreutils-python-utils
    runcmd:
      - [semanage, permissive, -a, virt_qemu_ga_t]
      - [dnf, config-manager, addrepo, --overwrite, --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo]
      - [dnf, install, -y, tailscale]
      - [systemctl, enable, --now, tailscaled, qemu-guest-agent]
      - [systemctl, restart, qemu-guest-agent, sshd]
  '';

  seed = pkgs.runCommand "${domainName}-seed.iso" { nativeBuildInputs = [ pkgs.cloud-utils ]; } ''
    cloud-localds $out ${userData} ${metaData}
  '';

  base = nixvirt.lib.domain.templates.linux {
    name = domainName;
    uuid = "19e091c9-57ac-4d5f-acc6-ecbd85cfa06f";
    vcpu.count = 8;
    memory = {
      count = 20;
      unit = "GiB";
    };
    storage_vol = diskPath;
    install_vol = seedPath;
    bridge_name = bridge;
    net_iface_mac = "52:54:00:f1:3d:01";
  };

  domain = base // {
    devices =
      removeAttrs base.devices [
        "graphics"
        "video"
        "sound"
        "audio"
        "redirdev"
        "input"
      ]
      // {
        channel = lib.filter (c: c.type != "spicevmc") base.devices.channel;
        serial = {
          type = "pty";
        };
        memballoon = {
          model = "virtio";
          freePageReporting = true;
        };
      };
  };

  network = {
    name = "default";
    uuid = "c334660a-d9b0-4b7d-8995-ea4d3a5a894e";
    forward.mode = "nat";
    bridge.name = bridge;
    mac.address = "52:54:00:f1:3d:00";
    ip = {
      address = "192.168.122.1";
      netmask = "255.255.255.0";
      dhcp.range = {
        start = "192.168.122.2";
        end = "192.168.122.254";
      };
    };
  };

  provision = pkgs.writeShellApplication {
    name = "${domainName}-provision";
    runtimeInputs = [
      pkgs.qemu-utils
      pkgs.coreutils
    ];
    text = ''
      install -d -m 0711 ${imageDir}
      if [ ! -e ${diskPath} ]; then
        qemu-img convert -O qcow2 ${fedoraCloud} ${diskPath}.tmp
        qemu-img resize ${diskPath}.tmp ${diskSize}
        mv ${diskPath}.tmp ${diskPath}
      fi
      install -m 0644 ${seed} ${seedPath}
    '';
  };

  guestHasSshSession = pkgs.writeShellApplication {
    name = "${domainName}-ssh-active";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      agent() { virsh -c qemu:///system qemu-agent-command ${domainName} "$1" 2>/dev/null; }
      pid=$(agent '{"execute":"guest-exec","arguments":{"path":"/usr/bin/pgrep","arg":["-f","^sshd-session: |tailscaled be-child ssh"]}}' | jq -e .return.pid) || exit 1
      for _ in 1 2 3 4 5; do
        status=$(agent "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}") || exit 1
        if [ "$(jq .return.exited <<<"$status")" = true ]; then
          [ "$(jq .return.exitcode <<<"$status")" = 0 ]
          exit
        fi
        sleep 1
      done
      exit 1
    '';
  };
in

{
  imports = [ nixvirt.nixosModules.default ];

  boot.kernelModules = [ "kvm-amd" ];

  virtualisation.libvirt = {
    enable = true;
    connections."qemu:///system" = {
      networks = [
        {
          definition = nixvirt.lib.network.writeXML network;
          active = true;
        }
      ];
      domains = [
        {
          definition = nixvirt.lib.domain.writeXML domain;
          active = true;
        }
      ];
    };
  };

  virtualisation.libvirtd = {
    onBoot = "ignore";
    onShutdown = "shutdown";
  };

  users.users.max.extraGroups = [ "libvirtd" ];

  systemd.services."${domainName}-provision" = {
    wantedBy = [ "nixvirt.service" ];
    before = [ "nixvirt.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe provision;
    };
  };

  local.server.ssh.hostOnlyInterfaces = [ bridge ];

  networking.firewall.interfaces.${bridge} = {
    allowedUDPPorts = [
      53
      67
    ];
    allowedTCPPorts = [ 53 ];
  };

  networking.nftables.tables.vm-isolation = {
    family = "inet";
    content = ''
      chain forward {
        type filter hook forward priority filter - 1; policy accept;

        iifname "${bridge}" meta nfproto ipv6 counter drop
        iifname "${bridge}" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } counter drop
        iifname "${bridge}" oifname != "${config.local.vpn.interface}" counter drop
      }
    '';
  };

  services.autosuspend.checks.FriendVmSsh = {
    class = "ExternalCommand";
    command = lib.getExe guestHasSshSession;
  };
}

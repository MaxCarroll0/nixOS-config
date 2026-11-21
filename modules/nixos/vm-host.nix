# Libvirt host for mc-server, a Fedora guest isolated from the LAN and tailnet.

{
  config,
  lib,
  pkgs,
  inputs,
  facts,
  ...
}:

let
  nixvirt = inputs.NixVirt;

  domainName = "mc-server";
  guestMac = "52:54:00:f1:3d:01";
  guestAddress = "192.168.122.108";
  bridgeAddress = "192.168.122.1";
  nasStreamPort = 8020;
  minecraftPort = 25565;
  hostTailnetAddress = facts.${config.networking.hostName}.tailscale;
  firstClassPeers = map (host: facts.${host}.tailscale) [
    "laptop"
    "pi"
    "fairphone"
  ];
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
    instance-id: damien-fedora-root
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
    net_iface_mac = guestMac;
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
      address = bridgeAddress;
      netmask = "255.255.255.0";
      dhcp = {
        range = {
          start = "192.168.122.2";
          end = "192.168.122.254";
        };
        host = {
          mac = guestMac;
          ip = guestAddress;
        };
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

  guestHoldLock = "/run/keep-running.lock";

  guestRun =
    name: path: args:
    pkgs.writeShellApplication {
      name = "${domainName}-${name}";
      runtimeInputs = [
        config.virtualisation.libvirtd.package
        pkgs.jq
        pkgs.coreutils
      ];
      excludeShellChecks = [ "SC2016" ];
      text = ''
        agent() { virsh -c qemu:///system qemu-agent-command ${domainName} "$1" 2>/dev/null; }
        pid=$(agent ${
          lib.escapeShellArg (
            builtins.toJSON {
              execute = "guest-exec";
              arguments = {
                inherit path;
                capture-output = true;
                arg = args;
              };
            }
          )
        } | jq -e .return.pid) || exit 1
        for _ in 1 2 3 4 5; do
          status=$(agent "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}") || exit 1
          if [ "$(jq .return.exited <<<"$status")" = true ]; then
            jq -j '.return."out-data" // "" | @base64d' <<<"$status"
            [ "$(jq .return.exitcode <<<"$status")" = 0 ]
            exit
          fi
          sleep 1
        done
        exit 1
      '';
    };

  guestLockCount = guestRun "lock-count" "/usr/bin/sh" [
    "-c"
    ''
      [ -e ${guestHoldLock} ] || /usr/bin/install -m 0644 /dev/null ${guestHoldLock}
      /usr/bin/chmod 0644 ${guestHoldLock}
      /usr/bin/lslocks -rn -o PATH | /usr/bin/grep -cx ${guestHoldLock} || true
    ''
  ];

  guestLoginCount = guestRun "login-count" "/usr/bin/sh" [
    "-c"
    ''
      count=0
      for session in $(/usr/bin/loginctl list-sessions --no-legend | /usr/bin/awk '$6 == "user" { print $1 }'); do
        [ "$(/usr/bin/loginctl show-session "$session" -p State --value)" = active ] && count=$((count + 1))
      done
      echo "$count"
    ''
  ];

  guestServerReadyAt = guestRun "server-ready-at" "/usr/bin/sh" [
    "-c"
    ''
      [ "$(/usr/bin/systemctl is-active minecraft)" = active ] || exit 0
      /usr/bin/systemctl show -P ActiveEnterTimestamp --timestamp=unix minecraft | /usr/bin/tr -d @
    ''
  ];

  lagStatus = "/run/${domainName}-lag.json";
  lagState = "/run/${domainName}-lag.state.json";

  guestLagSample = guestRun "lag-sample" "/usr/bin/sh" [
    "-c"
    (builtins.replaceStrings [ "@minecraftPort@" ] [ (toString minecraftPort) ] (
      builtins.readFile ./vm-host-lag-sample.sh
    ))
  ];

  lagUpdate = pkgs.writeShellApplication {
    name = "${domainName}-lag-update";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text =
      builtins.replaceStrings
        [
          "@guestLagSample@"
          "@lagState@"
          "@lagStatus@"
          "@program@"
          "@span@"
          "@busyLimit@"
          "@lossLimit@"
          "@lossMinBytes@"
          "@rttLimit@"
        ]
        [
          (lib.getExe guestLagSample)
          lagState
          lagStatus
          "${./vm-host-lag.jq}"
          "300"
          "0.8"
          "2"
          "524288"
          "150"
        ]
        (builtins.readFile ./vm-host-lag.sh);
  };

  vpnInterface = "proton-mc";
  vpnTable = 51821;
  vpnFwmark = "0xca6c";
  vpnLocalAddress = "10.2.0.3";
  vpnBootstrapConf = "/run/${domainName}-vpn/${vpnInterface}.conf";
  vpnStatus = "/run/${domainName}-vpn.json";
  vpnStateDir = "/var/lib/${domainName}-vpn";
  vpnSwitchUnit = "${domainName}-vpn-switch.service";

  vpnSwitch = pkgs.writeShellApplication {
    name = "${domainName}-vpn-switch";
    runtimeInputs = with pkgs; [
      (import ./protonvpn-wg-confgen.nix { inherit pkgs; })
      wireguard-tools
      util-linux
      coreutils
      gawk
      gnused
      gnugrep
      iputils
      jq
    ];
    text =
      builtins.replaceStrings
        [
          "@bypassResolvConf@"
          "@usernameFile@"
          "@passwordFile@"
          "@novpnGid@"
          "@interface@"
          "@stateDir@"
          "@statusFile@"
          "@country@"
          "@city@"
          "@pool@"
          "@maxAttempts@"
          "@fwmark@"
          "@healthProbe@"
          "@localAddress@"
        ]
        [
          "${pkgs.writeText "${vpnInterface}-resolv.conf" "nameserver ${config.local.vpn.bypassResolver}\n"}"
          config.sops.secrets.${config.local.vpn.usernameSecret}.path
          config.sops.secrets.${config.local.vpn.passwordSecret}.path
          (toString config.users.groups.novpn.gid)
          vpnInterface
          vpnStateDir
          vpnStatus
          "UK"
          "London"
          "12"
          "6"
          vpnFwmark
          config.local.vpn.healthProbe
          vpnLocalAddress
        ]
        (builtins.readFile ./vm-host-vpn-switch.sh);
  };

  vpnRoute = pkgs.writeShellApplication {
    name = "${domainName}-vpn-route";
    runtimeInputs = [ pkgs.iproute2 ];
    text = ''
      case "$1" in
        up)
          ip route replace default dev ${vpnInterface} table ${toString vpnTable}
          ip rule del priority 5200 2>/dev/null || true
          ip rule del priority 5201 2>/dev/null || true
          ip rule add iif ${bridge} to 100.64.0.0/10 lookup 52 priority 5200
          ip rule add iif ${bridge} lookup ${toString vpnTable} priority 5201
          ;;
        down)
          ip rule del priority 5200 2>/dev/null || true
          ip rule del priority 5201 2>/dev/null || true
          ip route flush table ${toString vpnTable} 2>/dev/null || true
          ;;
      esac
    '';
  };

  idleShutdownMinutes = 10;
  shutdownGraceMinutes = 6;
  idleCountdown = "${domainName}-idle-shutdown";
  idleStatus = "/run/${domainName}-idle.json";

  virsh = "virsh -c qemu:///system";

  shutdownRun = pkgs.writeShellApplication {
    name = "${domainName}-shutdown-run";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      pkgs.coreutils
    ];
    text = ''
      run=$1
      [ "$(${virsh} domid ${domainName} 2>/dev/null)" = "$run" ] || exit 0
      ${virsh} shutdown ${domainName}
      for _ in $(seq ${toString (shutdownGraceMinutes * 12)}); do
        [ "$(${virsh} domid ${domainName} 2>/dev/null)" = "$run" ] || exit 0
        sleep 5
      done
      ${virsh} destroy ${domainName}
    '';
  };

  shutdownWhenIdle = pkgs.writeShellApplication {
    name = "${domainName}-shutdown-when-idle";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      config.systemd.package
      pkgs.coreutils
      pkgs.jq
      config.local.power.keepAwakePackage
    ];
    text =
      builtins.replaceStrings
        [
          "@virsh@"
          "@domainName@"
          "@idleCountdown@"
          "@idleStatus@"
          "@guestLockCount@"
          "@guestLoginCount@"
          "@guestServerReadyAt@"
          "@idleAfter@"
          "@lagUpdate@"
          "@lagStatus@"
          "@lagState@"
        ]
        [
          "${virsh}"
          "${domainName}"
          "${idleCountdown}"
          "${idleStatus}"
          "${lib.getExe guestLockCount}"
          "${lib.getExe guestLoginCount}"
          "${lib.getExe guestServerReadyAt}"
          "${toString (idleShutdownMinutes * 60)}"
          "${lib.getExe lagUpdate}"
          lagStatus
          lagState
        ]
        (builtins.readFile ./vm-host-shutdown-when-idle.sh);
  };

  resume = pkgs.writeShellApplication {
    name = "${domainName}-resume";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
    ];
    text = ''
      case "$(${virsh} domstate ${domainName})" in
        paused)
          ${virsh} resume ${domainName} >/dev/null
          ${virsh} domtime ${domainName} --sync >/dev/null 2>&1 || true
          echo "${domainName}: resumed"
          ;;
        running)
          echo "${domainName}: already running"
          ;;
        *)
          ${virsh} start ${domainName} >/dev/null
          echo "${domainName}: booting, reachable in about a minute"
          ;;
      esac
    '';
  };

  remoteUser = "minecraft-remote";
  statusPort = 7782;

  control = pkgs.writeShellApplication {
    name = "${domainName}-control";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      config.systemd.package
      pkgs.jq
      pkgs.coreutils
    ];
    text =
      builtins.replaceStrings
        [
          "@virsh@"
          "@domainName@"
          "@idleStatus@"
          "@resume@"
          "@lagStatus@"
          "@vpnStatus@"
          "@vpnSwitchUnit@"
        ]
        [
          "${virsh}"
          "${domainName}"
          "${idleStatus}"
          "${lib.getExe resume}"
          lagStatus
          vpnStatus
          vpnSwitchUnit
        ]
        (builtins.readFile ./vm-host-control.sh);
  };
in

{
  imports = [
    nixvirt.nixosModules.default
    ./wake-endpoint.nix
    ./vm-guard.nix
  ];

  local.vmGuard.enable = true;

  boot.kernelModules = [ "kvm-amd" ];

  virtualisation.libvirt = {
    enable = true;
    connections."qemu:///system" = {
      networks = [
        {
          definition = nixvirt.lib.network.writeXML network;
          active = true;
          restart = false;
        }
      ];
      domains = [
        {
          definition = nixvirt.lib.domain.writeXML domain;
          active = null;
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
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;

        iifname "${bridge}" ip saddr ${guestAddress} ip daddr ${bridgeAddress} tcp dport ${toString nasStreamPort} dnat ip to ${facts.pi.tailscale}
      }

      chain forward {
        type filter hook forward priority filter - 1; policy accept;

        iifname "${bridge}" ip saddr ${guestAddress} ip daddr ${facts.pi.tailscale} oifname "tailscale0" tcp dport ${toString nasStreamPort} accept
        iifname "${bridge}" meta nfproto ipv6 counter drop
        iifname "${bridge}" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } counter drop
        iifname "${bridge}" oifname != "${vpnInterface}" counter drop
      }
    '';
  };

  systemd.sockets."${domainName}-minecraft" = {
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = "${hostTailnetAddress}:${toString minecraftPort}";
      FreeBind = true;
      IPAddressAllow = firstClassPeers ++ [ hostTailnetAddress ];
      IPAddressDeny = "any";
    };
  };

  systemd.services."${domainName}-minecraft" = {
    requires = [ "${domainName}-minecraft.socket" ];
    after = [ "${domainName}-minecraft.socket" ];
    serviceConfig = {
      ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd --exit-idle-time=10min ${guestAddress}:${toString minecraftPort}";
      DynamicUser = true;
      IPAddressAllow = guestAddress;
      IPAddressDeny = "any";
      RestrictAddressFamilies = [ "AF_INET" ];
      PrivateDevices = true;
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      CapabilityBoundingSet = "";
    };
  };

  networking.firewall.extraInputRules = ''
    iifname "tailscale0" ip saddr { ${lib.concatStringsSep ", " firstClassPeers} } tcp dport ${toString minecraftPort} accept
  '';

  systemd.services."${domainName}-shutdown-when-idle" = {
    after = [ "nixvirt.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe shutdownWhenIdle;
    };
  };

  systemd.timers."${idleCountdown}@" = {
    timerConfig = {
      OnActiveSec = "${toString idleShutdownMinutes}min";
      RemainAfterElapse = false;
    };
  };

  systemd.services."${idleCountdown}@" = {
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe shutdownRun} %i";
    };
  };

  systemd.timers."${domainName}-shutdown-when-idle" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
    };
  };

  local.wakeEndpoint.command = lib.getExe resume;
  users.users.vm-wake = {
    isSystemUser = true;
    group = "vm-wake";
    extraGroups = [ "libvirtd" ];
  };
  users.groups.vm-wake = { };

  systemd.services."wake-endpoint@".serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "vm-wake";
  };

  users.users.${remoteUser} = {
    isSystemUser = true;
    group = remoteUser;
    extraGroups = [ "libvirtd" ];
    useDefaultShell = true;
    openssh.authorizedKeys.keys = [
      ''restrict,command="${lib.getExe control} remote" ${builtins.readFile ../../keys/satisfactory-remote.pub}''
    ];
  };
  users.groups.${remoteUser} = { };

  local.server.ssh.allowUsers = [ remoteUser ];

  systemd.sockets."${domainName}-status" = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ (toString statusPort) ];
    socketConfig.Accept = true;
  };
  systemd.services."${domainName}-status@" = {
    serviceConfig = {
      ExecStart = "${lib.getExe control} status-http";
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "journal";
      LogLevelMax = "notice";
      User = remoteUser;
      RuntimeMaxSec = 10;
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ statusPort ];

  local.vpn.allowInterfaces = [ vpnInterface ];
  networking.networkmanager.unmanaged = [ "interface-name:${vpnInterface}" ];

  networking.wg-quick.interfaces.${vpnInterface} = {
    configFile = vpnBootstrapConf;
    autostart = true;
  };

  networking.nftables.tables.${vpnInterface} = {
    family = "ip";
    content = ''
      chain prerouting {
        type filter hook prerouting priority raw - 10; policy accept;
        iifname "${vpnInterface}" ip daddr 10.2.0.2 ip daddr set ${vpnLocalAddress}
      }

      chain postrouting {
        type filter hook postrouting priority srcnat + 10; policy accept;
        oifname "${vpnInterface}" ip saddr ${vpnLocalAddress} ip saddr set 10.2.0.2
      }
    '';
  };

  systemd.services."${domainName}-vpn-bootstrap" = {
    description = "Generate the initial London Proton config for ${vpnInterface}";
    before = [ "wg-quick-${vpnInterface}.service" ];
    wantedBy = [ "wg-quick-${vpnInterface}.service" ];
    after = [
      "sops-install-secrets.service"
      "network-online.target"
      "wg-quick-${config.local.vpn.interface}.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Group = "novpn";
      StateDirectory = "${domainName}-vpn";
      ExecStart = "${lib.getExe vpnSwitch} --bootstrap ${vpnBootstrapConf}";
      Restart = "on-failure";
      RestartSec = 5;
      StartLimitIntervalSec = 60;
      StartLimitBurst = 8;
    };
  };

  systemd.services."wg-quick-${vpnInterface}".serviceConfig = {
    Restart = "on-failure";
    RestartSec = 5;
    StartLimitIntervalSec = 60;
    StartLimitBurst = 8;
  };

  systemd.services."${domainName}-vpn-route" = {
    description = "Route ${bridge} through ${vpnInterface}";
    after = [ "wg-quick-${vpnInterface}.service" ];
    bindsTo = [ "wg-quick-${vpnInterface}.service" ];
    wantedBy = [ "wg-quick-${vpnInterface}.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${lib.getExe vpnRoute} up";
      ExecStop = "${lib.getExe vpnRoute} down";
    };
  };

  systemd.services.${lib.removeSuffix ".service" vpnSwitchUnit} = {
    description = "Move ${vpnInterface} to another London Proton server";
    after = [ "wg-quick-${vpnInterface}.service" ];
    requisite = [ "wg-quick-${vpnInterface}.service" ];
    startLimitIntervalSec = 600;
    startLimitBurst = 3;
    serviceConfig = {
      Type = "oneshot";
      Group = "novpn";
      StateDirectory = "${domainName}-vpn";
      ExecStart = lib.getExe vpnSwitch;
      TimeoutStartSec = "3min";
    };
  };

  security.polkit.extraConfig = ''
    polkit.addRule(function (action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units"
          && action.lookup("unit") == "${vpnSwitchUnit}"
          && action.lookup("verb") == "start"
          && (subject.user == "${remoteUser}" || subject.user == "max")) {
        return polkit.Result.YES;
      }
    });
  '';
}

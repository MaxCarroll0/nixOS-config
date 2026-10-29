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

  idlePauseMinutes = 15;
  lastActive = "/run/${domainName}-last-active";
  idleStatus = "/run/${domainName}-idle.json";

  virsh = "virsh -c qemu:///system";

  pauseWhenIdle = pkgs.writeShellApplication {
    name = "${domainName}-pause-when-idle";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      now=$(date +%s)
      running=false
      loggedIn=false
      if [ "$(${virsh} domstate ${domainName})" = running ]; then
        running=true
        if ${lib.getExe guestHasSshSession}; then
          loggedIn=true
        fi
      fi
      if [ "$running" = false ] || [ "$loggedIn" = true ] || [ ! -e ${lastActive} ]; then
        echo "$now" > ${lastActive}
      fi
      pausesAt=$(( $(cat ${lastActive}) + ${toString (idlePauseMinutes * 60)} ))
      jq -cn --argjson loggedIn "$loggedIn" --argjson running "$running" --argjson pausesAt "$pausesAt" \
        --argjson updated "$now" --argjson idleAfter ${toString (idlePauseMinutes * 60)} \
        '{loggedIn:$loggedIn,updated:$updated,idleAfter:$idleAfter,pausesAt:(if $running and ($loggedIn|not) then $pausesAt else null end)}' \
        > ${idleStatus}.tmp
      mv ${idleStatus}.tmp ${idleStatus}
      if [ "$running" = true ] && [ "$loggedIn" = false ] && [ "$now" -ge "$pausesAt" ]; then
        ${virsh} suspend ${domainName}
      fi
    '';
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

  isRunning = pkgs.writeShellApplication {
    name = "${domainName}-running";
    runtimeInputs = [ config.virtualisation.libvirtd.package ];
    text = ''
      [ "$(${virsh} domstate ${domainName} 2>/dev/null)" = running ]
    '';
  };

  remoteUser = "minecraft-remote";
  statusPort = 7782;

  control = pkgs.writeShellApplication {
    name = "${domainName}-control";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      pkgs.jq
    ];
    text = ''
      state() { ${virsh} domstate ${domainName} 2>/dev/null || echo unknown; }
      status_json() {
        local current idle='{}'
        current=$(state)
        if [ "$current" = running ] && [ -r ${idleStatus} ]; then
          idle=$(cat ${idleStatus})
        fi
        jq -cn --arg state "$current" --argjson idle "$idle" '{state:$state} + $idle'
      }

      case "''${1:-}" in
        remote)
          case "''${SSH_ORIGINAL_COMMAND:-}" in
            start)
              ${lib.getExe resume} >&2
              echo '{"ok":true}'
              ;;
            stop)
              if [ "$(state)" = paused ]; then
                ${virsh} resume ${domainName} >/dev/null
              fi
              ${virsh} shutdown ${domainName} >&2
              echo '{"ok":true}'
              ;;
            status) status_json ;;
            *)
              echo "usage: start | stop | status" >&2
              exit 2
              ;;
          esac
          ;;
        status-http)
          while IFS= read -r -t 2 line; do
            line=''${line%$'\r'}
            [ -z "$line" ] && break
          done
          body=$(status_json)
          printf 'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
            "''${#body}" "$body"
          ;;
        *)
          echo "usage: ${domainName}-control remote | status-http" >&2
          exit 2
          ;;
      esac
    '';
  };
in

{
  imports = [
    nixvirt.nixosModules.default
    ./wake-endpoint.nix
  ];

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

  systemd.services."${domainName}-pause-when-idle" = {
    after = [ "nixvirt.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe pauseWhenIdle;
    };
  };

  systemd.timers."${domainName}-pause-when-idle" = {
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
      User = remoteUser;
      RuntimeMaxSec = 10;
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ statusPort ];

  services.autosuspend.checks.FriendVmRunning = {
    class = "ExternalCommand";
    command = lib.getExe isRunning;
  };
}

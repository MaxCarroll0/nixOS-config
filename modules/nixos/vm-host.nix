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
  facts = import ../../hosts/facts.nix;

  domainName = "damien-fedora";
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

  idleShutdownMinutes = 10;
  shutdownGraceMinutes = 6;
  lastActive = "/run/${domainName}-last-active";
  shutdownRequested = "/run/${domainName}-shutdown-requested";
  idleStatus = "/run/${domainName}-idle.json";

  virsh = "virsh -c qemu:///system";

  shutdownWhenIdle = pkgs.writeShellApplication {
    name = "${domainName}-shutdown-when-idle";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      pkgs.coreutils
      pkgs.jq
      config.local.power.keepAwakePackage
    ];
    text = ''
      count() {
        local n
        n=$("$1") || n=0
        if [[ "$n" =~ ^[0-9]+$ ]]; then echo "$n"; else echo 0; fi
      }

      now=$(date +%s)
      running=false
      locks=0
      logins=0
      readyAt=0
      case "$(${virsh} domstate ${domainName})" in
        running | "in shutdown")
          running=true
          locks=$(count ${lib.getExe guestLockCount})
          logins=$(count ${lib.getExe guestLoginCount})
          readyAt=$(count ${lib.getExe guestServerReadyAt})
          ;;
      esac

      if [ "$running" = false ] || [ $((locks + logins)) -gt 0 ] || [ ! -e ${lastActive} ]; then
        echo "$now" > ${lastActive}
        rm -f ${shutdownRequested}
      fi
      activeUntil=$(cat ${lastActive})
      if [ "$readyAt" -gt "$activeUntil" ] && [ "$readyAt" -le "$now" ]; then
        activeUntil=$readyAt
      fi
      shutsDownAt=$(( activeUntil + ${toString (idleShutdownMinutes * 60)} ))
      idle=false
      starting=false
      if [ "$running" = true ] && [ $((locks + logins)) -eq 0 ]; then
        idle=true
        [ "$readyAt" -gt 0 ] || starting=true
      fi

      jq -cn --argjson locks "$locks" --argjson logins "$logins" --argjson idle "$idle" --argjson starting "$starting" \
        --argjson shutsDownAt "$shutsDownAt" --argjson updated "$now" \
        --argjson stopping "$([ -e ${shutdownRequested} ] && echo true || echo false)" \
        --argjson idleAfter ${toString (idleShutdownMinutes * 60)} \
        '{locks:$locks,logins:$logins,starting:$starting,stopping:$stopping,updated:$updated,idleAfter:$idleAfter,shutsDownAt:(if $idle then $shutsDownAt else null end)}' \
        > ${idleStatus}.tmp
      mv ${idleStatus}.tmp ${idleStatus}

      if [ "$running" = false ]; then
        keep-awake --release ${domainName}
      elif [ "$idle" = true ]; then
        keep-awake --take ${domainName} --drain --for 3m --why "${domainName} idle" >/dev/null
      else
        keep-awake --take ${domainName} --for 3m --why "${domainName} in use" >/dev/null
      fi

      if [ "$idle" = true ] && [ "$now" -ge "$shutsDownAt" ]; then
        if [ ! -e ${shutdownRequested} ]; then
          echo "$now" > ${shutdownRequested}
          ${virsh} shutdown ${domainName}
        elif [ $((now - $(cat ${shutdownRequested}))) -ge ${toString (shutdownGraceMinutes * 60)} ]; then
          ${virsh} destroy ${domainName}
        fi
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

  local.vpn.moderateNat = true;

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
        iifname "${bridge}" oifname != "${config.local.vpn.interface}" counter drop
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
      User = remoteUser;
      RuntimeMaxSec = 10;
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ statusPort ];
}

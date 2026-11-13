# Idle power policy and power measurement.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.power;

  powerReport = pkgs.writeShellApplication {
    name = "power-report";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.bc
      pkgs.curl
      pkgs.jq
      pkgs.gnuplot
    ];
    text = builtins.readFile ./power-report.sh;
  };

  powerStats = pkgs.writeShellApplication {
    name = "power-stats";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = builtins.readFile ./power-stats.sh;
  };

  # kscreen-doctor has to reach the Wayland session, which a root unit can only
  # do by borrowing the seat user's bus.
  sessionKscreen = pkgs.writeShellApplication {
    name = "session-kscreen";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.kdePackages.libkscreen
      pkgs.util-linux
    ];
    text = ''
      session_uid="''${SUDO_UID:-1000}"
      session_user="''${SUDO_USER:-max}"
      runtime_dir="/run/user/$session_uid"
      for socket in "$runtime_dir"/wayland-*; do
        [ -S "$socket" ] || continue
        exec runuser -u "$session_user" -- env \
          XDG_RUNTIME_DIR="$runtime_dir" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
          WAYLAND_DISPLAY="$(basename "$socket")" \
          kscreen-doctor "$@"
      done
      exit 0
    '';
  };

  # PowerDevil goes on believing the output is on, so a blank driven from
  # outside it is undone by nothing but whoever left this stamp behind.
  forcedOff = "/run/dpms-forced-off";
  parked = "/run/usb-idle-parked";
  lastInput = "/run/usb-last-input";

  softPowerCommand =
    name: service: dpms:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.systemd
      ];
      text = ''
        if [ "$(id -u)" -ne 0 ]; then
          echo "run with sudo" >&2
          exit 1
        fi

        systemctl start ${service}.service
        ${lib.getExe sessionKscreen} --dpms ${dpms}
        ${if dpms == "off" then "touch ${forcedOff}" else "rm -f ${forcedOff}"}
      '';
    };

  peripherals = pkgs.writeShellScript "usb-peripherals" ''
    for device in /sys/bus/usb/devices/*; do
      [ -w "$device/power/control" ] || continue
      [ "$(cat "$device/bDeviceClass" 2>/dev/null || true)" = "09" ] && continue
      [ -d "$device/net" ] && continue
      echo "$device"
    done
    exit 0
  '';

  # Matched by interface class as well as id, so swapping in a different audio
  # interface or keyboard does not need the exclusion list editing.
  neverSuspend = pkgs.writeShellScript "usb-never-suspend" (
    lib.optionalString (cfg.idle.usb.neverSuspend != [ ]) ''
      id="$(cat "$1/idVendor" 2>/dev/null || true):$(cat "$1/idProduct" 2>/dev/null || true)"
      case "$id" in
        ${lib.concatStringsSep "|" cfg.idle.usb.neverSuspend}) exit 0 ;;
      esac
    ''
    + lib.optionalString (cfg.idle.usb.neverSuspendClasses != [ ]) ''
      for interface in "$1"/*:*; do
        case "$(cat "$interface/bInterfaceClass" 2>/dev/null || true)" in
          ${lib.concatStringsSep "|" cfg.idle.usb.neverSuspendClasses}) exit 0 ;;
        esac
      done
    ''
    + "exit 1\n"
  );

  # A device the port never brought up stays invisible until it is replugged;
  # cycling the port's power is that replug, without the walk to the machine.
  resetEmptyPorts = pkgs.writeShellApplication {
    name = "usb-reset-empty-ports";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      # Normal enumeration has to finish first, or a slow device gets cycled
      # halfway up and has to start again.
      sleep "''${1:-15}"

      empty=()
      for port in /sys/bus/usb/devices/*/*-port*; do
        [ -w "$port/disable" ] || continue
        [ "$(cat "$port/state" 2>/dev/null || true)" = "not attached" ] || continue
        empty+=("$port")
      done
      [ ''${#empty[@]} -gt 0 ] || exit 0

      # Cut every port first and settle once. Toggling one port straight back
      # is not a power cycle the device ever sees -- measured 2026-10-08, 26
      # ports cycled that way and the Focusrite stayed dark -- and settling
      # each in turn would cost two seconds a port on every resume.
      for port in "''${empty[@]}"; do
        echo 1 > "$port/disable" || true
      done
      sleep 2
      for port in "''${empty[@]}"; do
        echo 0 > "$port/disable" || true
      done

      echo "power-cycled ''${#empty[@]} empty ports"
    '';
  };

  # sddm 0.21 respawns the greeter after a session ends with an empty socket
  # name, so it exits at once ("QLocalSocket::connectToServer: Invalid name")
  # and leaves seat0 dark until sddm itself restarts.
  reviveGreeter = pkgs.writeShellApplication {
    name = "revive-greeter";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      systemctl is-active --quiet display-manager.service || exit 0
      [ -z "$(loginctl show-seat seat0 --property=Sessions --value)" ] || exit 0
      systemctl restart display-manager.service
    '';
  };

  usbSuspendDelayMs = toString (cfg.idle.usb.suspendDelayMinutes * 60 * 1000);

  # Switch events are skipped: an audio interface reporting a jack is not a
  # user asking for their peripherals back.
  inputWake = pkgs.writeShellApplication {
    name = "input-wake";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.libinput
      pkgs.systemd
    ];
    text = ''
      # Without this the park clock would already read ten minutes old on a
      # fresh boot, and the peripherals would go down before anyone touched them.
      touch ${lastInput}

      last=0
      libinput debug-events --quiet --compress-motion-events | while read -r line; do
        case "$line" in
          *KEYBOARD_KEY* | *POINTER_* | *TOUCH_* | *TABLET_*) ;;
          *) continue ;;
        esac

        # EPOCHSECONDS, not date: motion arrives hundreds of times a second and
        # a fork each would cost more than the parking saves.
        now=$EPOCHSECONDS
        [ $((now - last)) -ge 5 ] || continue
        last=$now
        touch ${lastInput}

        if [ -e ${parked} ] || [ -e ${forcedOff} ]; then
          systemctl start wake-soft-hardware.service
          rm -f ${parked}
          if [ -e ${forcedOff} ]; then
            for blank in /sys/class/graphics/fb*/blank; do
              echo 0 > "$blank" || true
            done
            ${lib.getExe sessionKscreen} --dpms on
            rm -f ${forcedOff}
            ${lib.getExe reviveGreeter}
          fi
        fi
      done
    '';
  };

  usbIdlePark = pkgs.writeShellApplication {
    name = "usb-idle-park";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      # Parking with no watcher running would strand the peripherals: nothing
      # else turns them back on.
      systemctl is-active --quiet input-wake.service || exit 0

      if [ -e ${parked} ]; then
        exit 0
      fi

      stamp=$(stat -c %Y ${lastInput} 2>/dev/null || echo 0)
      if [ $(( $(date +%s) - stamp )) -lt ${toString (cfg.idle.usb.suspendDelayMinutes * 60)} ]; then
        exit 0
      fi

      systemctl start suspend-soft-hardware.service
      touch ${parked}
    '';
  };

  headlessPark = pkgs.writeShellApplication {
    name = "headless-park";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.procps
      pkgs.systemd
    ];
    text = ''
      for _ in $(seq 60); do
        pgrep -f '/bin/Hyprland' > /dev/null || break
        sleep 0.5
      done
      systemctl start suspend-soft-hardware.service
      touch ${parked} ${forcedOff}
      for blank in /sys/class/graphics/fb*/blank; do
        echo 4 > "$blank" || true
      done
    '';
  };

  suspendSoft = softPowerCommand "suspend-soft" "suspend-soft-hardware" "off";
  wakeSoft = softPowerCommand "wake-soft" "wake-soft-hardware" "on";
  sessionActivity = pkgs.writeShellApplication {
    name = "session-activity";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      procps
      systemd
    ];
    text = builtins.replaceStrings [ "@idleSeconds@" ] [ (toString (cfg.idle.autosuspend.idleMinutes * 60)) ] (builtins.readFile ./session-activity.sh);
  };

  keepAwake = pkgs.writeShellApplication {
    name = "keep-awake";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
    ];
    text = builtins.replaceStrings [ "@sleep@" ] [ "${pkgs.coreutils}/bin/sleep" ] (builtins.readFile ./keep-awake.sh);
  };

  keepAwakeActive = pkgs.writeShellApplication {
    name = "keep-awake-active";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      procps
      systemd
    ];
    text = ''
      # A block lock on idle is not a claim about work: Steam and KDE take one
      # whenever a game or video plays, which would pin the host awake forever.
      pids=$(busctl --json=short call org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager ListInhibitors \
        | jq -r '.data[0][]
                 | select(.[3] == "block")
                 | select(.[1] != "keep-awake-drain")
                 | select(.[0] | split(":") | any(. == "sleep" or . == "shutdown"))
                 | .[5]')

      [ -n "$pids" ] || exit 1

      ${lib.optionalString (cfg.idle.autosuspend.maxHoldHours != null) ''
        fresh=""
        for pid in $pids; do
          age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
          [ -n "$age" ] || continue
          if [ "$age" -lt ${toString (cfg.idle.autosuspend.maxHoldHours * 3600)} ]; then
            fresh="yes"
          fi
        done
        [ -n "$fresh" ] || exit 1
      ''}

      exit 0
    '';
  };

  deepSleepTarget = "/run/deep-sleep-target";

  disarmWakeSources = ''
    for node in ${toString cfg.idle.disableWakeSources}; do
      echo disabled > "$node/power/wakeup" 2>/dev/null || true
    done
  '';

  suspendThenPowerOff =
    hours:
    pkgs.writeShellApplication {
      name = "suspend-then-power-off";
      runtimeInputs = with pkgs; [
        coreutils
        gawk
        systemd
      ];
      text = builtins.replaceStrings [ "@hoursSeconds@" "@deepSleepTarget@" ] [ (toString (hours * 3600)) deepSleepTarget ] (builtins.readFile ./suspend-then-power-off.sh);
    };
in

{
  options.local.power = {
    instrument = lib.mkEnableOption "below, powertop snapshots and the power CLI tools";

    idle.optimise = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Cut idle draw without suspending. Applies under every policy.";
    };

    oopsPanic = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Reboot on a kernel Oops; turn off to keep the trace for diagnosis.";
    };

    idle.policy = lib.mkOption {
      type = lib.types.enum [
        "always-on"
        "scheduled"
        "autosuspend"
      ];
      default = "always-on";
      description = ''
        always-on   never suspends; anything hosted here stays reachable
        scheduled   suspends between sleepAt and wakeAt, RTC wakeup
        autosuspend suspends whenever idle checks all report inactive
      '';
    };

    idle.scheduled.sleepAt = lib.mkOption {
      type = lib.types.str;
      default = "01:00";
    };

    idle.scheduled.wakeAt = lib.mkOption {
      type = lib.types.str;
      default = "08:00";
    };

    idle.autosuspend.idleMinutes = lib.mkOption {
      type = lib.types.int;
      default = 20;
    };

    idle.autosuspend.loadThreshold = lib.mkOption {
      type = lib.types.float;
      default = 2.5;
      description = "Load average above which the host counts as busy.";
    };

    idle.autosuspend.watchPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 22 ];
      description = "A direct connection to any of these counts as activity; Tailscale SSH is invisible here.";
    };

    idle.autosuspend.powerOffAfterHours = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Escalate from suspend to power off after this long still idle.";
    };

    idle.autosuspend.keepAwake = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Honour block inhibitors and ship the keep-awake helper.";
    };

    idle.autosuspend.keepAwakeGroup = lib.mkOption {
      type = lib.types.str;
      default = "wheel";
      description = "Members may hold the host awake from a session with no seat.";
    };

    idle.autosuspend.maxHoldHours = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Stop honouring an inhibitor once its holder is this old.";
    };

    idle.autosuspend.watchInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.optional (cfg.wakeOnLan.interface != null) cfg.wakeOnLan.interface;
      defaultText = lib.literalExpression "[ config.local.power.wakeOnLan.interface ]";
      description = "Traffic on these counts as activity.";
    };

    idle.autosuspend.bandwidthThreshold = lib.mkOption {
      type = lib.types.int;
      # An idle host already sits near 0.5 MB/s on telemetry and scrapes alone,
      # while a real download runs 13 MB/s and up.
      default = 1000000;
      description = "Bytes per second, each direction, above which traffic counts as work.";
    };

    idle.disableWakeSources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/sys/bus/usb/devices/usb1" ];
      description = "Sysfs device paths, globs allowed, that must not wake the host.";
    };

    idle.usb.neverSuspend = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "1235:8202" ];
      description = "USB vendor:product ids that must keep runtime power management off.";
    };

    idle.usb.neverSuspendClasses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "01" ];
      description = "USB interface classes, in hex, that must keep runtime power management off.";
    };

    idle.usb.suspendDelayMinutes = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Minutes of inactivity before a USB device parks itself.";
    };

    idle.usb.resetEmptyPorts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Power-cycle hub ports that report no device, to force re-enumeration.";
    };

    keepAwakePackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = keepAwake;
      defaultText = lib.literalExpression "keep-awake";
      description = "The keep-awake helper, for modules that hold leases of their own.";
    };

    wakeOnLan.interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    wakeOnLan.mac = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Recorded here for the client side; Nix cannot set the BIOS.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = (cfg.wakeOnLan.interface == null) == (cfg.wakeOnLan.mac == null);
          message = "local.power.wakeOnLan needs both interface and mac, or neither.";
        }
      ];

      warnings = lib.optional (
        cfg.idle.policy != "always-on" && cfg.wakeOnLan.mac == null
      ) "idle.policy \"${cfg.idle.policy}\" with no Wake-on-LAN, so nothing can wake this host remotely.";

      environment.systemPackages = [
        powerReport
        powerStats
      ]
      ++ (with pkgs; [
        below
        btop
        powertop
        powerstat
        s-tui
        lm_sensors
        wtfutil
      ])
      ++ lib.optionals cfg.idle.optimise [
        suspendSoft
        wakeSoft
        pkgs.nvtopPackages.amd
      ];

    }

    (lib.mkIf (cfg.wakeOnLan.interface != null) {
      networking.interfaces.${cfg.wakeOnLan.interface}.wakeOnLan.enable = true;

      environment.systemPackages = [ pkgs.ethtool ];

      networking.networkmanager.ensureProfiles.profiles.${cfg.wakeOnLan.interface} = {
        connection = {
          id = cfg.wakeOnLan.interface;
          type = "802-3-ethernet";
          interface-name = cfg.wakeOnLan.interface;
          autoconnect = true;
        };
        # NM_SETTING_WIRED_WAKE_ON_LAN_MAGIC. The keyfile parser rejects the
        # name "magic" here: it only accepts the numeric flag.
        "802-3-ethernet".wake-on-lan = 64;
        ipv4.method = "auto";
        ipv6.method = "auto";
      };

      networking.networkmanager.dispatcherScripts = [
        {
          type = "basic";
          source = pkgs.writeShellScript "arm-wake-on-lan" ''
            [ "$1" = "${cfg.wakeOnLan.interface}" ] || exit 0
            case "$2" in
              up|dhcp4-change) ${pkgs.ethtool}/bin/ethtool -s "$1" wol g || true ;;
            esac
          '';
        }
      ];

      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="net", NAME=="${cfg.wakeOnLan.interface}", RUN+="${pkgs.ethtool}/bin/ethtool -s ${cfg.wakeOnLan.interface} wol g"
        ACTION=="add", SUBSYSTEM=="net", NAME=="${cfg.wakeOnLan.interface}", RUN+="${pkgs.iproute2}/bin/ip link set ${cfg.wakeOnLan.interface} up"
        ACTION=="add|change", SUBSYSTEM=="pci", DRIVERS=="r8169", ATTR{power/wakeup}="enabled"
      '';

      # r8169 clears the WoL bit during shutdown, so S5 wake needs it re-armed
      # after the network stack is gone but before power is cut.
      systemd.services.wake-on-lan-shutdown = {
        description = "Re-arm Wake-on-LAN across shutdown";
        wantedBy = [ "final.target" ];
        after = [ "final.target" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.ethtool}/bin/ethtool -s ${cfg.wakeOnLan.interface} wol g";
        };
      };

      powerManagement.powerDownCommands = "${pkgs.ethtool}/bin/ethtool -s ${cfg.wakeOnLan.interface} wol g";
    })

    (lib.mkIf cfg.idle.optimise {
      boot.kernelParams = [ "amd_pstate=guided" ];
      powerManagement.enable = true;
      powerManagement.cpuFreqGovernor = "schedutil";
      powerManagement.powertop.enable = true;

      hardware.bluetooth.powerOnBoot = false;

      # A parked input device that never had remote wakeup armed cannot resume
      # itself, so neither a keypress nor mouse movement reaches the session.
      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="scsi_host", KERNEL=="host*", ATTR{link_power_management_policy}="med_power_with_dipm"
        ACTION=="add|change", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", TEST=="power/control", ATTR{power/autosuspend_delay_ms}="${usbSuspendDelayMs}", ATTR{power/control}="auto"
        ACTION=="add|change", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"
      ''
      # Later rules win, so the exceptions have to follow the blanket ones.
      + lib.concatMapStrings (
        id:
        let
          parts = lib.splitString ":" id;
        in
        ''
          ACTION=="add|change", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="${lib.elemAt parts 0}", ATTR{idProduct}=="${lib.elemAt parts 1}", ATTR{power/control}="on"
        ''
      ) cfg.idle.usb.neverSuspend;

      systemd.services.usb-autosuspend = {
        description = "Re-pin USB runtime power management after powertop";
        after = [ "powertop.service" ];
        # powertop is itself ordered after multi-user.target, so pulling this in
        # from that target too made systemd drop the job to break the cycle.
        wantedBy = [ "powertop.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          for device in /sys/bus/usb/devices/*; do
            if [ -w "$device/power/wakeup" ]; then
              echo enabled > "$device/power/wakeup"
            fi
            [ -w "$device/power/control" ] || continue
            if ${neverSuspend} "$device"; then
              echo on > "$device/power/control"
              continue
            fi
            echo ${usbSuspendDelayMs} > "$device/power/autosuspend_delay_ms"
            echo auto > "$device/power/control"
          done
        '';
      };

      systemd.services.suspend-soft-hardware = {
        description = "Park peripherals without suspending the system";
        serviceConfig.Type = "oneshot";
        script = ''
          ${peripherals} | while read -r device; do
            if ${neverSuspend} "$device"; then continue; fi
            echo 0 > "$device/power/autosuspend_delay_ms"
            echo auto > "$device/power/control"
          done

          sleep 3

          ${peripherals} | while read -r device; do
            if ${neverSuspend} "$device"; then continue; fi
            echo ${usbSuspendDelayMs} > "$device/power/autosuspend_delay_ms"
          done

          for device in /sys/block/*; do
            if [ "$(cat "$device/queue/rotational" 2>/dev/null || true)" = 1 ]; then
              ${pkgs.hdparm}/bin/hdparm -y "/dev/$(basename "$device")"
            fi
          done
        '';
      };
      systemd.services.wake-soft-hardware = {
        description = "Restore peripheral power without changing the system power state";
        serviceConfig.Type = "oneshot";
        script = ''
          ${peripherals} | while read -r device; do
            echo on > "$device/power/control"
            if ${neverSuspend} "$device"; then continue; fi
            echo ${usbSuspendDelayMs} > "$device/power/autosuspend_delay_ms"
            echo auto > "$device/power/control"
          done
        '';
      };

      systemd.services.headless-park = {
        description = "Park peripherals and power the panel down once the session has ended";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe headlessPark;
        };
      };

      security.polkit.extraConfig = ''
        polkit.addRule(function (action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units"
              && action.lookup("unit") == "headless-park.service"
              && action.lookup("verb") == "start"
              && subject.user == "max") {
            return polkit.Result.YES;
          }
        });
      '';

      systemd.services.usb-reset-empty-ports = lib.mkIf cfg.idle.usb.resetEmptyPorts {
        description = "Re-enumerate USB ports that came up with no device";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-udevd.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe resetEmptyPorts;
        };
      };

      systemd.services.input-wake = {
        description = "Unpark peripherals on manual input";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = lib.getExe inputWake;
          Restart = "always";
          RestartSec = 5;
        };
      };

      # The host can be idle and still ineligible for suspend: a long build or a
      # live SSH session holds it awake, and the peripherals should park anyway.
      systemd.services.usb-idle-park = {
        description = "Park peripherals once manual input has stopped";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe usbIdlePark;
        };
      };
      systemd.timers.usb-idle-park = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "1min";
        };
      };

      powerManagement.powerDownCommands = ''
        ${pkgs.systemd}/bin/systemctl start suspend-soft-hardware.service
        ${pkgs.coreutils}/bin/touch ${parked}
      '';

      powerManagement.resumeCommands = ''
        ${pkgs.systemd}/bin/systemctl start wake-soft-hardware.service
        # disableWakeSources disarms the root hubs on the way down and nothing
        # used to arm them again, so a parked keyboard could not wake itself
        # through them and a keypress never reached the session.
        ${pkgs.systemd}/bin/systemctl start usb-autosuspend.service
        ${lib.optionalString cfg.idle.usb.resetEmptyPorts "${lib.getExe resetEmptyPorts} 5 || true"}
        ${pkgs.coreutils}/bin/rm -f ${parked} ${forcedOff}
        ${pkgs.coreutils}/bin/touch ${lastInput}
        # kde#523504 again: the greeter dies if the output is driven while it is
        # still initialising, so let the session settle before asserting DPMS.
        ${pkgs.coreutils}/bin/sleep 2
        ${lib.getExe sessionKscreen} --dpms on || true
        ${lib.getExe reviveGreeter} || true
      '';
    })

    (lib.mkIf (cfg.idle.policy == "always-on") {
      boot.kernelParams = [
        "panic=10"
      ]
      ++ lib.optional cfg.oopsPanic "oops=panic";

      boot.kernel.sysctl."kernel.panic_on_oops" = if cfg.oopsPanic then 1 else 0;

      systemd.settings.Manager = {
        RuntimeWatchdogSec = "60s";
        RebootWatchdogSec = "3min";
      };

      systemd.enableEmergencyMode = false;
    })

    (lib.mkIf (cfg.idle.policy == "scheduled") {
      systemd.timers.scheduled-suspend = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.idle.scheduled.sleepAt;
          Persistent = false;
        };
      };

      systemd.services.scheduled-suspend = {
        serviceConfig.Type = "oneshot";
        # wakeAt is a time of day; pick its next occurrence.
        script = ''
          now=$(${pkgs.coreutils}/bin/date +%s)
          target=$(${pkgs.coreutils}/bin/date -d '${cfg.idle.scheduled.wakeAt}' +%s)
          if [ "$target" -le "$now" ]; then
            target=$(${pkgs.coreutils}/bin/date -d 'tomorrow ${cfg.idle.scheduled.wakeAt}' +%s)
          fi
          ${pkgs.util-linux}/bin/rtcwake -m no -t "$target"
          ${pkgs.systemd}/bin/systemctl suspend
        '';
      };
    })

    (lib.mkIf (cfg.idle.policy == "autosuspend") {
      services.autosuspend = {
        enable = true;
        settings = {
          idle_time = cfg.idle.autosuspend.idleMinutes * 60;
          suspend_cmd =
            if cfg.idle.autosuspend.powerOffAfterHours == null then
              "${pkgs.systemd}/bin/systemctl suspend"
            else
              lib.getExe (suspendThenPowerOff cfg.idle.autosuspend.powerOffAfterHours);
        };
        checks = {
          SessionActivity = {
            class = "ExternalCommand";
            command = lib.getExe sessionActivity;
          };
          Load = {
            class = "Load";
            threshold = cfg.idle.autosuspend.loadThreshold;
          };
        }
        // lib.optionalAttrs cfg.idle.autosuspend.keepAwake {
          KeepAwake = {
            class = "ExternalCommand";
            command = lib.getExe keepAwakeActive;
          };
        }
        // lib.optionalAttrs (cfg.idle.autosuspend.watchInterfaces != [ ]) {
          NetworkBandwidth = {
            interfaces = lib.concatStringsSep "," cfg.idle.autosuspend.watchInterfaces;
            threshold_send = cfg.idle.autosuspend.bandwidthThreshold;
            threshold_receive = cfg.idle.autosuspend.bandwidthThreshold;
          };
        }
        // lib.optionalAttrs (cfg.idle.autosuspend.watchPorts != [ ]) {
          SshConnections = {
            class = "ActiveConnection";
            ports = lib.concatMapStringsSep "," toString cfg.idle.autosuspend.watchPorts;
          };
        };
      };
    })

    (lib.mkIf (cfg.idle.disableWakeSources != [ ]) {
      powerManagement.powerDownCommands = disarmWakeSources;
    })

    (lib.mkIf (cfg.idle.policy == "autosuspend" && cfg.idle.autosuspend.keepAwake) {
      environment.systemPackages = [ keepAwake ];

      # login1 ships these as allow_active, so a session with no seat - every SSH
      # login, and the lingering user manager a lease runs under - is refused.
      security.polkit.enable = true;
      security.polkit.extraConfig = ''
        polkit.addRule(function (action, subject) {
          var inhibits = [
            "org.freedesktop.login1.inhibit-block-sleep",
            "org.freedesktop.login1.inhibit-block-shutdown",
            "org.freedesktop.login1.suspend",
            "org.freedesktop.login1.suspend-multiple-sessions",
            "org.freedesktop.login1.power-off",
            "org.freedesktop.login1.power-off-multiple-sessions"
          ];
          if (inhibits.indexOf(action.id) >= 0
              && subject.isInGroup("${cfg.idle.autosuspend.keepAwakeGroup}")) {
            return polkit.Result.YES;
          }
        });
      '';
    })

    (lib.mkIf (cfg.idle.policy == "autosuspend" && cfg.idle.autosuspend.powerOffAfterHours != null) {
      systemd.services.deep-sleep-escalate = {
        description = "Power off when a timed wake finds the host still idle";
        serviceConfig.Type = "oneshot";
        script = ''
          sleep 5
          if ${lib.getExe keepAwakeActive} || ${lib.getExe sessionActivity}; then
            exit 0
          fi
          ${pkgs.systemd}/bin/systemctl poweroff
        '';
      };

      powerManagement.resumeCommands = lib.mkBefore ''
        target=$(cat ${deepSleepTarget} 2>/dev/null || echo 0)
        rm -f ${deepSleepTarget}
        echo 0 > /sys/class/rtc/rtc0/wakealarm
        if [ "$target" -gt 0 ] && [ "$(${pkgs.coreutils}/bin/date +%s)" -ge "$(( target - 60 ))" ]; then
          ${pkgs.systemd}/bin/systemctl start --no-block deep-sleep-escalate.service
        fi
      '';
    })

    (lib.mkIf cfg.instrument {
      services.below = {
        enable = true;
        collect.ioStats = true;
        retention.time = 24 * 60 * 60;
      };

    })
  ];
}

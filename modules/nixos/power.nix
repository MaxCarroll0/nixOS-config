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
    text = ''
      interval="''${1:-5}"
      history="''${2:-24 hours}"
      declare -A before
      available=0
      domains=0
      for d in /sys/class/powercap/*/; do
        [ -e "$d/energy_uj" ] || continue
        available=$((available + 1))
        [ -r "$d/energy_uj" ] || continue
        before["$d"]=$(cat "$d/energy_uj")
        domains=$((domains + 1))
      done
      if [ "$domains" -eq 0 ]; then
        if [ "$available" -eq 0 ]; then
          echo "no powercap energy counters found." >&2
        else
          echo "no readable powercap domains." >&2
          echo "energy_uj is root-only since Linux 5.10; set" >&2
          echo "local.monitoring.userReadable = true, or run this as root." >&2
        fi
        exit 1
      fi
      sleep "$interval"
      for d in /sys/class/powercap/*/; do
        [ -r "$d/energy_uj" ] || continue
        name=$(cat "$d/name" 2>/dev/null || basename "$d")
        after=$(cat "$d/energy_uj")
        delta=$(( after - ''${before["$d"]} ))
        # The counter wraps at max_energy_range_uj.
        if [ "$delta" -lt 0 ]; then
          range=$(cat "$d/max_energy_range_uj" 2>/dev/null || echo 0)
          [ "$range" -gt 0 ] || continue
          delta=$(( delta + range ))
        fi
        printf '%-24s %6.2f W\n' "$name" "$(echo "scale=2; $delta / 1000000 / $interval" | bc)"
      done

      start=$(date --date="$history ago" +%s)
      end=$(date +%s)
      reports=$(mktemp --directory)
      trap 'rm -rf "$reports"' EXIT

      graph() {
        key="$1"
        title="$2"
        query="$3"
        report="$reports/$key"

        if ! curl --fail --silent --show-error --get \
          --data-urlencode "query=$query" \
          --data-urlencode "start=$start" \
          --data-urlencode "end=$end" \
          --data-urlencode "step=60" \
          http://127.0.0.1:9091/api/v1/query_range \
          | jq -r '.data.result[0].values[]? | "\(.[0]) \(.[1])"' > "$report"; then
          echo "could not read historical $title data" >&2
          return
        fi

        if [ ! -s "$report" ]; then
          echo "no historical $title data yet" >&2
          return
        fi

        printf '\n%s, last %s\n' "$title" "$history"
        gnuplot <<EOF
      set terminal dumb 100 20
      set xdata time
      set timefmt "%s"
      set format x "%H:%M"
      set ylabel "W"
      set yrange [0:*]
      plot "$report" using 1:2 with lines title "$title"
      EOF
      }

      graph total "Total" "avg1m:pc_power_watts"
      graph cpu "CPU" "avg1m:pc_cpu_power_watts"
      graph gpu "GPU" "avg1m:pc_gpu_power_watts"
    '';
  };

  powerStats = pkgs.writeShellApplication {
    name = "power-stats";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      metric_query() {
        case "$1" in
          total) echo 'avg1m:pc_power_watts' ;;
          cpu) echo 'avg1m:pc_cpu_power_watts' ;;
          gpu) echo 'avg1m:pc_gpu_power_watts' ;;
        esac
      }

      stat() {
        agg="$1"
        query="$2"
        range="$3"
        curl --fail --silent --show-error --get \
          --data-urlencode "query=''${agg}_over_time((''${query})[''${range}:1m])" \
          http://127.0.0.1:9091/api/v1/query \
          | jq -r '(.data.result[0].value[1] // "n/a") as $v
                   | if $v == "n/a" then $v else ($v | tonumber | (. * 100 | round) / 100 | tostring) end'
      }

      printf '%-12s %-6s %8s %8s %8s\n' metric range min avg max
      for key in total cpu gpu; do
        query=$(metric_query "$key")
        for range in 24h 7d 30d; do
          min=$(stat min "$query" "$range")
          avg=$(stat avg "$query" "$range")
          max=$(stat max "$query" "$range")
          printf '%-12s %-6s %8s %8s %8s\n' "$key" "$range" "$min" "$avg" "$max"
        done
      done
    '';
  };

  powertopSnapshot = pkgs.writeShellApplication {
    name = "powertop-snapshot";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.powertop
    ];
    text = ''
      exec powertop --quiet --csv="/var/log/powertop/$(date --utc +%Y%m%dT%H%M%SZ).csv" --time=10
    '';
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
            ${lib.getExe sessionKscreen} --dpms on
            rm -f ${forcedOff}
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
    text = ''
      resident=$(systemctl show -p MainPID --value nix-daemon.service 2>/dev/null || echo 0)
      for pid in $(pgrep -x nix-daemon || true); do
        if [ "$pid" != "$resident" ]; then
          exit 0
        fi
      done

      if [ "$resident" != 0 ] && pgrep -P "$resident" >/dev/null 2>&1; then
        exit 0
      fi

      if pgrep -f "[.]tailscaled-wrapped be-child ssh" >/dev/null 2>&1; then
        exit 0
      fi

      threshold=$(( $(date +%s) - ${toString (cfg.idle.autosuspend.idleMinutes * 60)} ))
      for pty in /dev/pts/*; do
        [ -c "$pty" ] || continue
        case "$pty" in
          */ptmx) continue ;;
        esac
        atime=$(stat -c %X "$pty" 2>/dev/null || echo 0)
        if [ "$atime" -gt "$threshold" ]; then
          exit 0
        fi
      done

      # Seatless sessions are skipped because tailscaled registers one per SSH
      # command, each of them type tty and never idle.
      for session in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
        [ "$(loginctl show-session "$session" -p Class --value)" = user ] || continue
        [ -n "$(loginctl show-session "$session" -p Seat --value)" ] || continue

        # IdleHint is never set under Wayland; the screen lock is, by KDE.
        if [ "$(loginctl show-session "$session" -p Type --value)" = tty ]; then
          if [ "$(loginctl show-session "$session" -p IdleHint --value)" != yes ]; then
            exit 0
          fi
          continue
        fi

        if [ "$(loginctl show-session "$session" -p LockedHint --value)" != yes ]; then
          exit 0
        fi
      done

      exit 1
    '';
  };

  keepAwake = pkgs.writeShellApplication {
    name = "keep-awake";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
    ];
    text = ''
      usage() {
        printf '%s\n' \
          'keep-awake [--why REASON] [--shutdown] [--] COMMAND [ARGS...]' \
          'keep-awake --for DURATION [--why REASON] [--shutdown]' \
          'keep-awake --take NAME [--why REASON] [--for DURATION] [--shutdown]' \
          'keep-awake --release NAME|all' \
          'keep-awake --list' \
          "" \
          'Holds a block inhibitor so the idle watcher leaves the host alone.' \
          'DURATION accepts 90, 30m, 2h.'
      }

      seconds() {
        case "$1" in
          *h) echo $(( ''${1%h} * 3600 )) ;;
          *m) echo $(( ''${1%m} * 60 )) ;;
          *s) echo "''${1%s}" ;;
          *) echo "$1" ;;
        esac
      }

      # Tailscale SSH exports a usable user bus but no XDG_RUNTIME_DIR.
      unit_scope() {
        if [ "$(id -u)" = 0 ]; then
          echo system
        elif [ -n "''${XDG_RUNTIME_DIR:-}" ] || [ -n "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
          echo user
        else
          echo system
        fi
      }

      scoped_systemctl() {
        if [ "$(unit_scope)" = user ]; then
          systemctl --user "$@"
        else
          systemctl "$@"
        fi
      }

      run_scoped() {
        if [ "$(unit_scope)" = user ]; then
          systemd-run --user "$@"
        else
          systemd-run "$@"
        fi
      }

      why="keep-awake"
      what="sleep"
      duration=""
      name=""
      release=""
      list=0

      while [ $# -gt 0 ]; do
        case "$1" in
          --why) why="$2"; shift 2 ;;
          --for) duration="$2"; shift 2 ;;
          --take) name="$2"; shift 2 ;;
          --release) release="$2"; shift 2 ;;
          --list) list=1; shift ;;
          --shutdown) what="sleep:shutdown"; shift ;;
          -h|--help) usage; exit 0 ;;
          --) shift; break ;;
          -*) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
          *) break ;;
        esac
      done

      if [ "$list" -eq 1 ]; then
        systemd-inhibit --list --no-pager
        exit 0
      fi

      if [ -n "$release" ]; then
        if [ "$release" = all ]; then
          scoped_systemctl stop 'keep-awake-*' 2>/dev/null || true
        else
          scoped_systemctl stop "keep-awake-$release.service" 2>/dev/null || true
        fi
        exit 0
      fi

      if [ -n "$name" ]; then
        unit="keep-awake-$name"
        secs=$(seconds "''${duration:-24h}")
        if scoped_systemctl is-active --quiet "$unit.service" 2>/dev/null; then
          if [ -z "$duration" ]; then
            exit 0
          fi
          scoped_systemctl stop "$unit.service" 2>/dev/null || true
        fi
        run_scoped --quiet --collect --unit "$unit" \
          --property=RuntimeMaxSec="$secs" \
          --description="keep-awake: $why" \
          -- systemd-inhibit --mode=block --what="$what" --who=keep-awake --why="$why" \
            -- sleep "$secs"
        echo "$unit"
        exit 0
      fi

      if [ -n "$duration" ]; then
        secs=$(seconds "$duration")
        unit="keep-awake-$(date +%s)-$$"
        run_scoped --quiet --collect --unit "$unit" \
          --property=RuntimeMaxSec="$secs" \
          --description="keep-awake: $why" \
          -- systemd-inhibit --mode=block --what="$what" --who=keep-awake --why="$why" \
            -- sleep "$secs"
        echo "$unit"
        exit 0
      fi

      if [ $# -eq 0 ]; then
        usage >&2
        exit 2
      fi

      exec systemd-inhibit --mode=block --what="$what" --who=keep-awake --why="$why" -- "$@"
    '';
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
      text = ''
        alarm=/sys/class/rtc/rtc0/wakealarm
        target=$(( $(date +%s) + ${toString (hours * 3600)} ))

        # Writing a wakealarm that is already armed fails EBUSY.
        echo 0 > "$alarm"
        echo "$target" > "$alarm"
        echo "$target" > ${deepSleepTarget}

        # systemctl suspend returns once logind accepts the request, not on
        # resume, so whether to power off is decided by resumeCommands.
        # A refused suspend must disarm both, or the next resume reads a target
        # already in the past and escalates to poweroff.
        # Not --check-inhibitors=yes: that also refuses whenever any user is
        # logged in, and the autologin session on tty1 never goes away. The
        # default still lets logind honour block inhibitors.
        if ! systemctl suspend; then
          echo 0 > "$alarm"
          rm -f ${deepSleepTarget}
          exit 1
        fi
      '';
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
        ${lib.getExe sessionKscreen} --dpms on
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

      powerManagement.resumeCommands = ''
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

      systemd.services.powertop-snapshot = {
        description = "Record device power states and wakeups";
        serviceConfig = {
          ExecStart = lib.getExe powertopSnapshot;
          LogsDirectory = "powertop";
          LogsDirectoryMode = "0750";
          Type = "oneshot";
        };
      };

      systemd.timers.powertop-snapshot = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5m";
          OnUnitActiveSec = "15m";
          Persistent = true;
          RandomizedDelaySec = "30s";
        };
      };

      systemd.tmpfiles.rules = [
        "d /var/log/powertop 0750 root root 30d"
      ];
    })
  ];
}

# A 4-wire PWM fan on a GPIO hardware-PWM channel, curved off drive temperature.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.gpioPwmFan;

  runDir = "/run/gpio-pwm-fan";
  pwmPath = "${runDir}/pwm";

  # RP1 exposes pwm0 and pwm1; GPIO12/13 live on the lower-addressed one.
  resolveChip = ''
    chip=$(
      for c in /sys/class/pwm/pwmchip*; do
        dev=$(readlink -f "$c/device" 2>/dev/null) || continue
        case "$dev" in
          *.pwm) echo "''${dev##*/} $c" ;;
        esac
      done | sort | head -n1 | cut -d' ' -f2
    )
    if [ -z "$chip" ]; then
      echo "no hardware PWM chip found; is the pwm-2chan overlay enabled?" >&2
      exit 1
    fi
  '';

  init = pkgs.writeShellApplication {
    name = "gpio-pwm-fan-init";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      ${resolveChip}

      pwm=$chip/pwm${toString cfg.channel}
      if [ ! -d "$pwm" ]; then
        echo ${toString cfg.channel} > "$chip/export"
      fi

      for _ in $(seq 50); do
        if [ -w "$pwm/period" ]; then
          break
        fi
        sleep 0.1
      done

      echo 0 > "$pwm/duty_cycle"
      echo ${toString cfg.periodNs} > "$pwm/period"
      echo 1 > "$pwm/enable"

      mkdir -p ${runDir}
      ln -sfn "$pwm" ${pwmPath}
    '';
  };

  setPwm = pkgs.writeShellApplication {
    name = "gpio-pwm-fan-set";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      value=''${1:?usage: gpio-pwm-fan-set 0..255}
      period=$(cat ${pwmPath}/period)
      echo $(( value * period / 255 )) > ${pwmPath}/duty_cycle
    '';
  };

  getPwm = pkgs.writeShellApplication {
    name = "gpio-pwm-fan-get";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      period=$(cat ${pwmPath}/period)
      duty=$(cat ${pwmPath}/duty_cycle)
      echo $(( duty * 255 / period ))
    '';
  };

  # Reading drivetemp resets the spin-down timer on some drives; hdparm -C does not.
  driveTemp = pkgs.writeShellApplication {
    name = "drive-temp-millicelsius";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hdparm
    ];
    text = ''
      found=0
      max=0
      for name in /sys/class/hwmon/*/name; do
        if [ "$(cat "$name")" != "drivetemp" ]; then
          continue
        fi
        found=1
        chip=''${name%/name}

        asleep=0
        for block in "$chip"/device/block/*; do
          if [ -e "$block" ] && ! hdparm -C "/dev/''${block##*/}" | grep -q "active/idle"; then
            asleep=1
          fi
        done
        if [ "$asleep" -eq 1 ]; then
          continue
        fi

        for input in "$chip"/temp*_input; do
          if [ -r "$input" ]; then
            value=$(cat "$input")
            if [ "$value" -gt "$max" ]; then
              max=$value
            fi
          fi
        done
      done
      last=/run/drive-temp-millicelsius
      if [ "$found" -eq 0 ]; then
        echo ${toString cfg.noSensorMillicelsius}
      elif [ "$max" -gt 0 ]; then
        echo "$max" | tee "$last"
      elif [ -s "$last" ]; then
        cat "$last"
      else
        echo ${toString cfg.asleepMillicelsius}
      fi
    '';
  };

  failsafeValue = cfg.failsafePercent * 255 / 100;
in

{
  options.local.gpioPwmFan = {
    enable = lib.mkEnableOption "PWM fan on a GPIO hardware-PWM channel";

    channel = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "PWM channel to export; 0 is GPIO12 under the pwm-2chan overlay.";
    };

    periodNs = lib.mkOption {
      type = lib.types.int;
      default = 40000;
      description = "PWM period; the 4-wire fan spec asks for 25 kHz.";
    };

    failsafePercent = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = "Duty cycle applied when the controlling daemon exits.";
    };

    failsafeUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Units whose exit should drive the fan to failsafePercent.";
    };

    noSensorMillicelsius = lib.mkOption {
      type = lib.types.int;
      default = 60000;
      description = "Temperature reported when no drivetemp sensor is present.";
    };

    asleepMillicelsius = lib.mkOption {
      type = lib.types.int;
      default = 30000;
      description = "Temperature assumed when every drive is asleep and none has been read yet.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      init
      setPwm
      getPwm
      driveTemp
    ];

    systemd.services = lib.mkMerge [
      {
        gpio-pwm-fan-init = {
          description = "Export and configure the GPIO PWM fan channel";
          after = [ "systemd-udev-settle.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe init;
          };
        };
      }
      (lib.genAttrs (map (lib.removeSuffix ".service") cfg.failsafeUnits) (_: {
        after = [ "gpio-pwm-fan-init.service" ];
        requires = [ "gpio-pwm-fan-init.service" ];
        serviceConfig.ExecStopPost = "-${lib.getExe setPwm} ${toString failsafeValue}";
      }))
    ];
  };
}

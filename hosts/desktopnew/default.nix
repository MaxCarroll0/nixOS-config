# New AMD desktop hardware (Gigabyte board, post 2026-08-11 swap).

{
  config,
  pkgs,
  pkgs-unstable,
  ...
}:

let
  # VRM MOS is excluded: measured identical at 380 and 2169 rpm, so it is heated
  # by conduction from CPU package power and airflow cannot move it.
  caseTemp = pkgs.writeShellApplication {
    name = "case-temp-millicelsius";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      max=0
      for name in /sys/class/hwmon/*/name; do
        chip=''${name%/name}
        inputs=()
        case "$(cat "$name")" in
          zenpower) inputs=("$chip/temp1_input") ;;
          amdgpu) inputs=("$chip/temp1_input") ;;
          gigabyte_wmi) inputs=("$chip/temp2_input") ;;
          *) continue ;;
        esac
        for input in "''${inputs[@]}"; do
          if [ -r "$input" ]; then
            value=$(cat "$input")
            if [ "$value" -gt "$max" ]; then
              max=$value
            fi
          fi
        done
      done
      echo "$max"
    '';
  };
  # fan2go 0.13.0 never finishes analysing this fan: its RPM-curve measurement
  # waits for a zero reading that a fan with a 379 rpm floor never produces, so
  # the controller loop never starts while it keeps writing PWM. Drive it here.

  # The card's own curve parks the fan at 790 rpm, settles at 89 C under a 119 W
  # load and throttles to 108 W. fan2go cannot drive it either: like vrm_fan it
  # never finishes analysis, so it holds pwm without ever applying a curve.
  gpuFan = pkgs.writeShellApplication {
    name = "gpu-fan-control";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      for name in /sys/class/hwmon/*/name; do
        [ "$(cat "$name")" = amdgpu ] && gpu="''${name%/name}"
      done
      [ -n "''${gpu:-}" ] || exit 1
      echo 1 > "$gpu/pwm1_enable"

      while :; do
        t=$(( $(cat "$gpu/temp1_input") / 1000 ))
        if [ "$t" -le 50 ]; then
          pwm=0
        elif [ "$t" -le 60 ]; then
          pwm=$(( (t - 50) * 64 / 10 ))
        elif [ "$t" -le 70 ]; then
          pwm=$(( 64 + (t - 60) * 51 / 10 ))
        elif [ "$t" -le 78 ]; then
          pwm=$(( 115 + (t - 70) * 64 / 8 ))
        elif [ "$t" -le 85 ]; then
          pwm=$(( 179 + (t - 78) * 76 / 7 ))
        else
          pwm=255
        fi
        echo "$pwm" > "$gpu/pwm1"
        sleep 4
      done
    '';
  };
  vrmFan = pkgs.writeShellApplication {
    name = "vrm-fan-control";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      chip() {
        for name in /sys/class/hwmon/*/name; do
          if [ "$(cat "$name")" = "$1" ]; then
            echo "''${name%/name}"
            return
          fi
        done
      }
      wmi=$(chip gigabyte_wmi)
      hub=$(chip arctic_fan)
      [ -n "$wmi" ] && [ -n "$hub" ] || exit 1

      while :; do
        t=$(( $(cat "$wmi/temp5_input") / 1000 ))
        if [ "$t" -le 66 ]; then
          pwm=0
        elif [ "$t" -le 74 ]; then
          pwm=$(( (t - 66) * 76 / 8 ))
        elif [ "$t" -le 80 ]; then
          pwm=$(( 76 + (t - 74) * 77 / 6 ))
        elif [ "$t" -le 88 ]; then
          pwm=$(( 153 + (t - 80) * 102 / 8 ))
        else
          pwm=255
        fi
        echo "$pwm" > "$hub/pwm7"
        sleep 5
      done
    '';
  };
in

{
  imports = [
    ./hardware.nix
    ../desktop-common.nix
  ];

  networking.hostName = "desktopnew";

  # Headless: no connector is plugged in, so amdgpu exposes no CRTC and any GL or
  # Vulkan client fails to create a surface. Force one on.
  boot.kernelParams = [ "video=HDMI-A-1:1920x1080@60e" ];

  fileSystems."/boot".options = [
    "nofail"
    "x-systemd.automount"
  ];

  # This host's own key, so sudo-grant's agent can satisfy pam_ssh_agent_auth;
  # keys/max.pub is a different key and lives on no host's disk here.
  users.users.max.openssh.authorizedKeys.keyFiles = [ ../../keys/max-desktopnew.pub ];

  local.server.ssh.lanInterfaces = [ "enp5s0" ];

  local.fancontrol = {
    enable = true;
    configFile = ./fan2go-full.yaml;
  };

  environment.systemPackages = [ caseTemp ];

  systemd.services.gpu-fan = {
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" ];
    serviceConfig = {
      ExecStart = "${gpuFan}/bin/gpu-fan-control";
      ExecStopPost = "${pkgs.bash}/bin/bash -c 'for e in /sys/class/hwmon/*/pwm1_enable; do grep -q amdgpu \"$(dirname \"$e\")/name\" && echo 2 > \"$e\"; done'";
      Restart = "always";
      RestartSec = 5;
    };
  };
  systemd.services.vrm-fan = {
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" ];
    serviceConfig = {
      ExecStart = "${vrmFan}/bin/vrm-fan-control";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # arctic_fan_controller, for the 10-port USB fan controller, is new in 7.2.
  boot.kernelPackages = pkgs-unstable.linuxPackages_testing;

  boot.extraModulePackages = [ config.boot.kernelPackages.zenpower ];
  boot.kernelModules = [ "zenpower" ];

  boot.extraModprobeConfig = "options it87 force_id=0x8733";

  local.monitoring.sensorNames = {
    "zenpower:power1" = "CPU cores";
    "zenpower:power2" = "CPU SoC";
    "zenpower:temp1" = "CPU Tdie";
    "zenpower:temp2" = "CPU Tctl";
    "zenpower:temp3" = "CPU CCD1";
    "zenpower:temp4" = "CPU CCD2";
    "it8792:fan1" = "Radiator";
    "it8792:fan2" = "Pump";
    "arctic_fan:fan2" = "Intake vertical";
    "arctic_fan:fan3" = "Extraction";
    "arctic_fan:fan6" = "Intake horizontal";
    "arctic_fan:fan7" = "VRM";
    "gigabyte_wmi:temp1" = "System 1";
    "gigabyte_wmi:temp2" = "Chipset";
    "gigabyte_wmi:temp3" = "CPU socket";
    "gigabyte_wmi:temp4" = "PCIe x16";
    "gigabyte_wmi:temp5" = "VRM MOS";
    "gigabyte_wmi:temp6" = "VSoC MOS";
  };

  local.power.wakeOnLan = {
    interface = "enp5s0";
    mac = "b4:2e:99:92:d6:18";
  };
}

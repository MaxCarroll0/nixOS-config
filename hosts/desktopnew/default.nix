# New AMD desktop hardware (Gigabyte board, post 2026-08-11 swap).

{
  config,
  pkgs,
  pkgs-unstable,
  ...
}:

let
  # Case airflow tracks whichever of GPU, VRM or chipset is hottest; Tdie peaks
  # at 53 C under full load and would leave the later fan stages dormant.
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
          gigabyte_wmi) inputs=("$chip/temp2_input" "$chip/temp5_input") ;;
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

  local.server.ssh.lanInterfaces = [ "enp5s0" ];

  local.fancontrol = {
    enable = true;
    configFile = ./fan2go.yaml;
  };

  environment.systemPackages = [ caseTemp ];

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
    "it8792:fan1" = "CPU fan";
    "it8792:fan2" = "Chassis fan";
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

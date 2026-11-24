# AMD desktop hardware on a Gigabyte board.

{
  config,
  pkgs,
  facts,
  ...
}:

let
  # VRM MOS is excluded: its temperature follows CPU package power, not airflow.
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
in

{
  imports = [
    ./hardware.nix
    ../desktop-common.nix
    ./satisfactory.nix
    ../../modules/nixos/vm-host.nix
  ];

  networking.hostName = "desktopnew";

  services.ollama = {
    enable = true;
    package = pkgs.ollama-vulkan;
    loadModels = [ "qwen3-embedding:0.6b" ];
  };

  sops.secrets.jobs-worker-env = {
    sopsFile = ../../secrets/jobs-worker.env;
    format = "dotenv";
    owner = "max";
    mode = "0400";
  };

  fileSystems."/boot".options = [
    "nofail"
    "x-systemd.automount"
  ];

  # This host's own key: keys/max.pub lives on no host's disk here.
  users.users.max.openssh.authorizedKeys.keyFiles = [ ../../keys/max-desktopnew.pub ];

  local.server.ssh.lanInterfaces = [ "enp5s0" ];

  local.gaming.enable = true;
  local.desktop.plasma.enable = false;

  local.fancontrol = {
    enable = true;
    configFile = ./fan2go-full.yaml;
  };

  environment.systemPackages = [
    caseTemp
  ];
  # arctic_fan_controller drives the 10-port USB fan controller; it needs kernel 7.2.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # kswapd0 oopsed in __pgalloc_tag_sub on 7.4.0-rc2 (2026-11-17) and 7.3.4 (2026-11-24).
  boot.kernelParams = [ "sysctl.vm.mem_profiling=never" ];

  # Linux 7.3 no longer pulls asm/cpuid/api.h in through linux/pci.h.
  boot.extraModulePackages = [
    (config.boot.kernelPackages.zenpower.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        sed -i 's|^#include <linux/pci.h>$|&\n#include <asm/cpuid/api.h>|' zenpower.c
      '';
    }))
  ];
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

  # The Focusrite and G403 do not recover from a USB park without a replug.
  local.power.idle.usb.neverSuspend = [
    "1235:8202"
    "046d:c08f"
  ];

  # RESET_RESUME: the Focusrite is reset on resume rather than restored; once off the bus it stays off.
  boot.kernelParams = [ "usbcore.quirks=1235:8202:b" ];

  # serio0 and the Promontory root hubs latch an immediate S3 wake; a keypress cannot wake this board.
  local.power.idle.disableWakeSources = [
    "/sys/bus/serio/devices/serio0"
    "/sys/bus/pci/devices/0000:02:00.0/usb*"
  ];

  system.autoUpgrade.enable = true;

  local.power.wakeOnLan = {
    inherit (facts.desktopnew) interface mac;
  };
}

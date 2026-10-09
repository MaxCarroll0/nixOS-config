# New AMD desktop hardware (Gigabyte board, post 2026-08-11 swap).

{
  config,
  pkgs,
  pkgs-unstable,
  ...
}:

let
  facts = import ../facts.nix;

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
in

{
  imports = [
    ./hardware.nix
    ../desktop-common.nix
  ];

  networking.hostName = "desktopnew";

  fileSystems."/boot".options = [
    "nofail"
    "x-systemd.automount"
  ];

  # This host's own key, so sudo-grant's agent can satisfy pam_ssh_agent_auth;
  # keys/max.pub is a different key and lives on no host's disk here.
  users.users.max.openssh.authorizedKeys.keyFiles = [ ../../keys/max-desktopnew.pub ];

  local.server.ssh.lanInterfaces = [ "enp5s0" ];

  local.gaming.enable = true;

  local.fancontrol = {
    enable = true;
    configFile = ./fan2go-full.yaml;
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

  # Focusrite firmware does not survive a USB resume; it dropped off the bus.
  # The G403 goes silent once parked and a replug is the only way back.
  local.power.idle.usb.neverSuspend = [
    "1235:8202"
    "046d:c08f"
  ];

  # RESET_RESUME for the Focusrite: reset it on resume instead of restoring
  # state it cannot restore. Measured 2026-10-09, once it has dropped off the
  # bus nothing short of a replug brings it back -- a verified port disable
  # toggle and a full xhci_hcd unbind/rebind both left it absent -- so the only
  # thing left is to stop it dropping off in the first place. Untested through
  # a suspend as of writing.
  boot.kernelParams = [ "usbcore.quirks=1235:8202:b" ];

  # Both latch a wake as S3 is entered, resuming within milliseconds: serio0
  # raises IRQ 1 with no PS/2 keyboard attached, and the Promontory root hubs
  # assert PME with every device unbound.
  #
  # Measured 2026-10-08: sparing usb1 so a keypress could resume the host put
  # that straight back, suspending and exiting 4-5 s later every 11 minutes,
  # which also dropped the Focusrite off the bus. A keypress cannot wake this
  # board from S3; the power button, Wake-on-LAN and the RTC alarm can.
  local.power.idle.disableWakeSources = [
    "/sys/bus/serio/devices/serio0"
    "/sys/bus/pci/devices/0000:02:00.0/usb*"
  ];

  system.autoUpgrade.enable = true;

  local.power.wakeOnLan = {
    inherit (facts.desktopnew) interface mac;
  };
}

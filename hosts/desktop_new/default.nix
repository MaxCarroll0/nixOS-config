# New AMD desktop hardware (Gigabyte board, post 2026-08-11 swap).

{ ... }:

{
  imports = [
    ./hardware.nix
    ../desktop-common.nix
  ];

  networking.hostName = "desktop_new";

  # Headless: no connector is plugged in, so amdgpu exposes no CRTC and any GL or
  # Vulkan client fails to create a surface. Force one on.
  boot.kernelParams = [ "video=HDMI-A-1:1920x1080@60e" ];

  fileSystems."/boot".options = [
    "nofail"
    "x-systemd.automount"
  ];

  local.server.ssh.lanInterfaces = [ "enp5s0" ];

  local.fancontrol.configFile = ./fan2go.yaml;

  local.monitoring.sensorNames = {
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

# Prior AMD desktop hardware, pre 2026-08-11 motherboard swap.

{ ... }:

{
  imports = [
    ./hardware.nix
    ../desktop-common.nix
  ];

  networking.hostName = "desktop_old";

  local.server.ssh.lanInterfaces = [
    "enp6s0"
    "wlp5s0"
  ];

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
    interface = "enp6s0";
    mac = "70:85:c2:54:c6:89";
  };
}

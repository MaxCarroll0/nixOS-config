# Keep remote access, dashboards and telemetry responsive while bulk work saturates the box.

{ config, lib, ... }:

let
  cfg = config.local.servicePriority;
  unitName = lib.removeSuffix ".service";

  weights = {
    CPUWeight = 400;
    IOWeight = 400;
  };

  protect =
    attr: units:
    lib.mapAttrs' (
      unit: floor:
      lib.nameValuePair (unitName unit) {
        serviceConfig = weights // {
          ${attr} = floor;
        };
      }
    ) units;
in

{
  options.local.servicePriority = {
    enable = lib.mkEnableOption "resource protection for critical services";
    essential = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Units mapped to memory the kernel may never reclaim from them.";
    };

    critical = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Units mapped to memory reclaimed only after everything else.";
    };
    throttle = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Units mapped to the size above which they are reclaimed hard.";
    };

    bulk = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Units that must yield CPU and IO to the protected ones.";
    };

    bulkMemoryMax = lib.mkOption {
      type = lib.types.str;
      default = "256M";
      description = "Hard memory ceiling for bulk units, so they cannot force swapping.";
    };
    swappiness = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Low values reclaim page cache before swapping resident services.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelParams = [ "cgroup_enable=memory" ];

    boot.kernel.sysctl."vm.swappiness" = cfg.swappiness;

    systemd.services = lib.mkMerge [
      (protect "MemoryMin" cfg.essential)
      (protect "MemoryLow" cfg.critical)
      (lib.mapAttrs' (
        unit: ceiling: lib.nameValuePair (unitName unit) { serviceConfig.MemoryHigh = ceiling; }
      ) cfg.throttle)
      (lib.genAttrs (map unitName cfg.bulk) (_: {
        serviceConfig = {
          CPUWeight = 10;
          IOWeight = 10;
          Nice = 19;
          IOSchedulingClass = "idle";
          MemoryMax = lib.mkDefault cfg.bulkMemoryMax;
        };
      }))
    ];
  };
}

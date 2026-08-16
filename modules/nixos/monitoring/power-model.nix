# Per-host power model: what each machine is built from, in watts.

{ lib, ... }:

let
  wattsOption =
    default: description:
    lib.mkOption {
      type = lib.types.number;
      inherit default description;
    };

  diskProfileType = lib.types.submodule {
    options = {
      match = lib.mkOption {
        type = lib.types.str;
        description = "Substring of the sysfs model string, or @rotational, @nvme, @ssd.";
      };
      standbyWatts = wattsOption 0.6 "Draw with the motor stopped.";
      idleWatts = wattsOption 4.5 "Draw spinning or powered with no transfers.";
      activeWatts = wattsOption 6.5 "Draw under continuous transfer.";
      spinUpWatts = wattsOption 0 "Peak draw while the motor starts.";
    };
  };

  fanType = lib.types.submodule {
    options = {
      constantWatts = wattsOption 0 "Draw of a fan with no tachometer, assumed steady.";
      chip = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "hwmon chip name carrying this fan's tachometer.";
      };
      sensor = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "hwmon sensor key within the chip, such as fan1.";
      };
      maxRpm = lib.mkOption {
        type = lib.types.number;
        default = 0;
        description = "Tachometer reading at full speed.";
      };
      wattsAtMaxRpm = wattsOption 0 "Draw at full speed.";
      exponent = lib.mkOption {
        type = lib.types.number;
        default = 2.5;
        description = "Power-law index relating speed to draw.";
      };
    };
  };
in

{
  options.local.monitoring.power = {
    enable = lib.mkEnableOption "the component power model";

    supply = {
      ratedWatts = lib.mkOption {
        type = lib.types.number;
        default = 100;
        description = "Nameplate output of the supply, used to place the load on its curve.";
      };
      peakEfficiency = lib.mkOption {
        type = lib.types.number;
        default = 0.9;
        description = "Conversion efficiency at the best point of the curve.";
      };
      peakLoadRatio = lib.mkOption {
        type = lib.types.number;
        default = 0.45;
        description = "Fraction of rated output where efficiency peaks.";
      };
      curvature = lib.mkOption {
        type = lib.types.number;
        default = 0.6;
        description = "How sharply efficiency falls away from the peak.";
      };
      idleWatts = wattsOption 0.5 "Loss the supply draws with no load at all.";
    };

    ram = {
      modelled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether DRAM needs its own term, or is already inside a measured domain.";
      };
      wattsPerGiB = wattsOption 0.055 "Draw per installed GiB at rest.";
      activeWattsPerGiB = wattsOption 0.045 "Additional draw per GiB at full CPU load.";
    };

    gpu = {
      boardFactor = lib.mkOption {
        type = lib.types.number;
        default = 1.0;
        description = "Ratio of card draw to the GPU's own reported figure, above 1 where it reports die power.";
      };
      overheadWatts = wattsOption 0 "Card draw the GPU never reports, such as VRAM and VRM at idle.";
    };

    pmicEfficiency = lib.mkOption {
      type = lib.types.number;
      default = 1.0;
      description = "Conversion efficiency of the Pi PMIC feeding the measured rails.";
    };

    backlightMaxWatts = wattsOption 0 "Panel and backlight draw at full brightness.";

    boardWatts = wattsOption 0 "Chipset, VRM quiescent, NIC, audio and USB host draw.";

    peripheralsWatts = wattsOption 0 "Anything attached that reports nothing, such as radios or a HBA.";

    fans = lib.mkOption {
      type = lib.types.attrsOf fanType;
      default = { };
      description = "Fans keyed by a name shown on the breakdown.";
    };

    disks = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            standbyWatts = wattsOption 0.6 "Draw with the motor stopped.";
            idleWatts = wattsOption 4.5 "Draw powered with no transfers.";
            activeWatts = wattsOption 6.5 "Draw under continuous transfer.";
            spinUpWatts = wattsOption 0 "Peak draw while the motor starts.";
          };
        }
      );
      default = { };
      example = {
        sda.idleWatts = 0.6;
      };
      description = "Per-device overrides on top of the model table, keyed by kernel name.";
    };

    diskProfiles = lib.mkOption {
      type = lib.types.listOf diskProfileType;
      description = "Drive draw by model, first match wins, @-prefixed entries are fallbacks.";
      default = [
        {
          match = "ST4000DM004";
          standbyWatts = 0.25;
          idleWatts = 2.5;
          activeWatts = 5.0;
          spinUpWatts = 24.0;
        }
        {
          match = "ST2000DM006";
          standbyWatts = 0.6;
          idleWatts = 4.6;
          activeWatts = 7.2;
          spinUpWatts = 24.0;
        }
        {
          match = "ST1000VM002";
          standbyWatts = 0.5;
          idleWatts = 4.0;
          activeWatts = 5.0;
          spinUpWatts = 20.0;
        }
        {
          match = "@rotational";
          standbyWatts = 0.6;
          idleWatts = 4.5;
          activeWatts = 6.5;
          spinUpWatts = 24.0;
        }
        {
          match = "@nvme";
          standbyWatts = 0.05;
          idleWatts = 0.6;
          activeWatts = 6.0;
        }
        {
          match = "@ssd";
          standbyWatts = 0.05;
          idleWatts = 0.4;
          activeWatts = 2.0;
        }
      ];
    };

    meters = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        pi = "127.0.0.1:9110";
      };
      description = "Wall power meters scraped by the server to check the model, keyed by instance.";
    };
  };
}

# Prometheus recording rules for both downsampling hops, plus Grafana alert rules.

{ config, lib, ... }:

let
  cfg = config.local.monitoring;

  # The chip-keyed name wins where it exists; chip_name cannot separate sibling
  # chips that share a driver, such as one drivetemp per disk.
  named =
    metric:
    let
      chipped = "${metric} * on(instance, chip) group_left(chip_name) node_hwmon_chip_names";
    in
    "(${chipped} * on(instance, chip, sensor) group_left(name) node_sensor_chip)"
    + " or ((${chipped} unless on(instance, chip, sensor) node_sensor_chip)"
    + " * on(instance, chip_name, sensor) group_left(name) node_sensor_name)";

  sensorRules = {
    "sensor:temp_celsius" = named "node_hwmon_temp_celsius";
    "sensor:fan_rpm" = named "node_hwmon_fan_rpm";
    "sensor:power_watt" = named "node_hwmon_power_watt";
    "sensor:volts" = named "node_hwmon_in_volts";
    "fan:rpm" = ''label_replace(${named "node_hwmon_fan_rpm"}, "id", "$1", "name", "(.*)")'';
    "temp:major_celsius" =
      ''label_replace(max by (instance) (sensor:temp_celsius{name=~"CPU Tctl|CPU Tdie|CPU package|SoC"}), "component", "CPU", "", "")''
      + " or "
      + ''label_replace(max by (instance) (sensor:temp_celsius{name=~"GPU edge|GPU junction"}), "component", "GPU", "", "")''
      + " or "
      + ''label_replace(max by (instance) (sensor:temp_celsius{name=~"NVMe|Composite|HDD.*"}), "component", "Storage", "", "")''
      + " or "
      + ''label_replace(max by (instance) (sensor:temp_celsius{name=~"System 1|Ambient"}), "component", "Box", "", "")'';
  };

  coefficient = metric: "max by (instance) (${metric})";
  perDisk = metric: "max by (instance, device) (${metric})";
  perFan = metric: "max by (instance, fan) (${metric})";

  component = name: expr: ''label_replace(${expr}, "component", "${name}", "", "")'';

  raplPackage = ''rate(node_rapl_package_joules_total{path!~".*mmio.*"}[1m])'';

  plausible = ceiling: expr: "clamp_max(${expr}, ${toString ceiling})";

  hwmonPower = chipName: ''
    sum by (instance) (
      node_hwmon_power_watt
      and on(instance, chip) node_hwmon_chip_names{chip_name="${chipName}"}
    )'';

  powerRules = [
    {
      record = "pi:pmic_rail_watts";
      expr = "pi_pmic_current_amps * on(instance, rail) pi_pmic_voltage_volts";
    }
    {
      record = "pc:cpu_power_watts";
      expr = ''
        ${hwmonPower "zenpower"}
        or ${plausible 400 "sum by (instance) (${raplPackage})"}
        or sum by (instance) (pi:pmic_rail_watts{rail="VDD_CORE"})'';
    }
    {
      record = "pc:gpu_power_watts";
      expr = ''
        ${hwmonPower "amdgpu"} * ${coefficient "pc_power_gpu_board_factor"}
        + ${coefficient "pc_power_gpu_overhead_watts"}'';
    }
    {
      record = "pc:platform_power_watts";
      expr = plausible 1000 ''
        clamp_min(
          sum by (instance) (rate(node_rapl_psys_joules_total[1m]))
          - sum by (instance) (${raplPackage}),
          0)'';
    }
    {
      record = "pc:soc_rail_watts";
      expr = ''sum by (instance) (pi:pmic_rail_watts{rail!="VDD_CORE"})'';
    }
    {
      record = "pc:pmic_loss_watts";
      expr = ''
        sum by (instance) (pi:pmic_rail_watts)
        * (1 / ${coefficient "pc_power_pmic_efficiency"} - 1)'';
    }
    {
      record = "pc:ram_power_watts";
      expr = ''
        ${coefficient ''pc_power_ram_watts{state="idle"}''}
        + ${coefficient ''pc_power_ram_watts{state="active"}''}
        * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m])))'';
    }
    {
      record = "pc:backlight_power_watts";
      expr = "${coefficient "pc_power_backlight_max_watts"} * ${coefficient "pc_backlight_ratio"}";
    }
    {
      record = "pc:disk_standby";
      expr = perDisk "pc_disk_standby";
    }
    {
      record = "pc:disk_activity";
      expr = "clamp_max(sum by (instance, device) (rate(node_disk_io_time_seconds_total[1m])), 1)";
    }
    {
      record = "pc:disk_power_watts";
      expr = ''
        ${perDisk ''pc_power_disk_watts{state="standby"}''} * pc:disk_standby
        + (1 - pc:disk_standby)
        * (${perDisk ''pc_power_disk_watts{state="idle"}''}
           + (${perDisk ''pc_power_disk_watts{state="active"}''}
              - ${perDisk ''pc_power_disk_watts{state="idle"}''}) * pc:disk_activity)'';
    }
    {
      record = "pc:fan_rpm_modelled";
      expr = ''
        max by (instance, fan) (
          sensor:fan_rpm
          * on(instance, chip_name, sensor) group_left(fan)
          (max by (instance, chip_name, sensor, fan) (pc_power_fan_max_rpm) * 0 + 1)
        )'';
    }
    {
      record = "pc:fan_power_watts";
      expr = ''
        ${perFan "pc_power_fan_constant_watts"}
        or ${perFan "pc_power_fan_max_watts"}
        * clamp_max(pc:fan_rpm_modelled / ${perFan "pc_power_fan_max_rpm"}, 1)
        ^ ${perFan "pc_power_fan_exponent"}'';
    }
    {
      record = "pc:power_dc_component_watts";
      expr = lib.concatStringsSep "\n or " [
        (component "CPU" "pc:cpu_power_watts")
        (component "GPU" "pc:gpu_power_watts")
        (component "Platform" "pc:platform_power_watts")
        (component "SoC rails" "pc:soc_rail_watts")
        (component "PMIC loss" "pc:pmic_loss_watts")
        (component "RAM" "pc:ram_power_watts")
        (component "Display" "pc:backlight_power_watts")
        (component "Storage" "pc:disk_power_watts")
        (component "Fans" "pc:fan_power_watts")
        (component "Board" (coefficient "pc_power_board_watts"))
        (component "Peripherals" (coefficient "pc_power_peripherals_watts"))
      ];
    }
    {
      record = "pc:power_dc_watts";
      expr = "sum by (instance) (pc:power_dc_component_watts)";
    }
    {
      record = "pc:supply_load_ratio";
      expr = "pc:power_dc_watts / ${coefficient "pc_power_supply_rated_watts"}";
    }
    {
      record = "pc:supply_efficiency";
      expr = ''
        clamp(
          ${coefficient "pc_power_supply_peak_efficiency"}
          * (1 - ${coefficient "pc_power_supply_curvature"}
                 * (pc:supply_load_ratio
                    - ${coefficient "pc_power_supply_peak_load_ratio"}) ^ 2),
          0.5, 0.96)'';
    }
    {
      record = "pc:supply_loss_watts";
      expr = ''
        pc:power_dc_watts * (1 / pc:supply_efficiency - 1)
        + ${coefficient "pc_power_supply_idle_watts"}'';
    }
    {
      record = "pc:power_component_watts";
      expr = "pc:power_dc_component_watts or ${component "Supply loss" "pc:supply_loss_watts"}";
    }
    {
      record = "pc:power_watts";
      expr = "pc:power_dc_watts + pc:supply_loss_watts";
    }
    {
      record = "pc:power_meter_watts";
      expr = coefficient "pc_power_meter_watts";
    }
    {
      record = "pc:power_model_error_watts";
      expr = "pc:power_meter_watts - pc:power_watts";
    }
    {
      record = "pc:tariff_gbp_per_kwh";
      expr = coefficient "pc_power_tariff_gbp_per_kwh";
    }
  ];

  systemRules = {
    "cpu:utilisation" = ''1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m]))'';
    "cpu:core_utilisation" = ''1 - rate(node_cpu_seconds_total{mode="idle"}[15s])'';
    "cpu:core_utilisation_min" =
      ''min by (instance) (1 - rate(node_cpu_seconds_total{mode="idle"}[15s]))'';
    "cpu:core_utilisation_avg" =
      ''avg by (instance) (1 - rate(node_cpu_seconds_total{mode="idle"}[15s]))'';
    "cpu:core_utilisation_max" =
      ''max by (instance) (1 - rate(node_cpu_seconds_total{mode="idle"}[15s]))'';
    "cpu:hertz" = "avg by (instance) (node_cpu_scaling_frequency_hertz)";
    "cpu:hertz_min" = "min by (instance) (node_cpu_scaling_frequency_hertz)";
    "cpu:hertz_max" = "max by (instance) (node_cpu_scaling_frequency_hertz)";
    "cpu:throttled_ratio" =
      "1 - avg by (instance) (node_cpu_scaling_frequency_hertz)"
      + " / avg by (instance) (node_cpu_scaling_frequency_max_hertz)";
    "mem:used_bytes" = "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes";
    "mem:used_ratio" = "1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes";
    "mem:cached_bytes" = "node_memory_Cached_bytes + node_memory_Buffers_bytes";
    "mem:swap_used_bytes" = "node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes";
    "load:load1" = "node_load1";
    "load:pressure_ratio" =
      ''node_load1 / on(instance) count by (instance) (node_cpu_seconds_total{mode="idle"})'';
    "psi:cpu_waiting" = "rate(node_pressure_cpu_waiting_seconds_total[1m])";
    "psi:io_stalled" = "rate(node_pressure_io_stalled_seconds_total[1m])";
    "psi:memory_stalled" = "rate(node_pressure_memory_stalled_seconds_total[1m])";
    "disk:io_time" = "rate(node_disk_io_time_seconds_total[1m])";
    "disk:read_bytes" = "rate(node_disk_read_bytes_total[1m])";
    "disk:written_bytes" = "rate(node_disk_written_bytes_total[1m])";
    "fs:avail_bytes" = ''node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs"}'';
    "fs:free_ratio" =
      ''node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs"}''
      + ''/ node_filesystem_size_bytes{fstype!~"tmpfs|ramfs"}'';
    "systemd:failed_units" = ''sum by (instance) (node_systemd_unit_state{state="failed"})'';
    "host:up" =
      ''clamp_max(count by (instance) (present_over_time(up{job="node"}[1m])), 1)''
      + "* on(instance) group_left() "
      + ''(label_replace(max by (peer) (tailscale_peer_online{instance="pi"}), "instance", "$1", "peer", "(.+)")''
      + ''or max by (instance) (up{job="node", instance="pi"}))''
      + ''or (max by (instance) (last_over_time(up{job="node"}[7d])) * 0)''
      + ''or max by (instance) (label_replace(max by (peer) (last_over_time(tailscale_peer_online{instance="pi"}[7d])) * 0, "instance", "$1", "peer", "(.+)"))'';
    "host:boot_time_seconds" = "node_boot_time_seconds";
    "host:awake_since_seconds" = "node_awake_since_seconds";
  };

  # Installed hardware, not a workload signal: evaluated on its own slow group
  # so a value that changes only when the machine is opened up costs nothing.
  capacityRules = {
    "mem:total_bytes" = "node_memory_MemTotal_bytes";
    "mem:capacity_info" = "pc_memory_capacity_info";
    "mem:swap_total_bytes" = "node_memory_SwapTotal_bytes";
    "fs:size_bytes" = ''node_filesystem_size_bytes{fstype!~"tmpfs|ramfs"}'';
    "cpu:cores" = ''count by (instance) (node_cpu_seconds_total{mode="idle"})'';
  };

  byTransport =
    direction:
    let
      counter = "node_network_${direction}_bytes_total";
      tunnels = ''{device=~"proton.*|wg.*|tun.*"}'';
      tailnet = ''{device=~"tailscale.*"}'';
      physical = ''{device=~"en.*|eth.*|wl.*|ww.*|bond.*"}'';
      rated = selector: "sum by (instance) (rate(${counter}${selector}[1m]))";
      tagged = name: expr: ''label_replace(${expr}, "transport", "${name}", "", "")'';
      zero = "(0 * ${rated physical})";
      orZero = expr: "((${expr}) or ${zero})";
      direct = "clamp_min(${rated physical} - ${orZero (rated tunnels)} - ${orZero (rated tailnet)}, 0)";
    in
    lib.concatStringsSep " or " [
      (tagged "VPN" (rated tunnels))
      (tagged "Tailnet" (rated tailnet))
      (tagged "Direct" direct)
    ];

  networkRules = {
    "net:receive_bytes" =
      ''sum by (instance, device) (rate(node_network_receive_bytes_total{device!="lo"}[1m]))'';
    "net:transmit_bytes" =
      ''sum by (instance, device) (rate(node_network_transmit_bytes_total{device!="lo"}[1m]))'';
    "net:receive_errors" =
      ''sum by (instance, device) (rate(node_network_receive_errs_total{device!="lo"}[1m]))'';
    "net:transmit_errors" =
      ''sum by (instance, device) (rate(node_network_transmit_errs_total{device!="lo"}[1m]))'';
    "net:receive_drops" =
      ''sum by (instance, device) (rate(node_network_receive_drop_total{device!="lo"}[1m]))'';
    "net:receive_bytes_by_transport" = byTransport "receive";
    "net:transmit_bytes_by_transport" = byTransport "transmit";
    "ts:peer_rx_bytes" = "rate(tailscale_peer_rx_bytes_total[1m])";
    "ts:peer_tx_bytes" = "rate(tailscale_peer_tx_bytes_total[1m])";
    "ts:peer_online" = "tailscale_peer_online";
    "ts:peer_direct" = "tailscale_peer_direct";
    # A peer that has never handshaken reports epoch 0; without the guard its
    # age reads as the whole Unix epoch.
    "ts:handshake_age_seconds" =
      "(time() - tailscale_peer_last_handshake_seconds)"
      + " and (tailscale_peer_last_handshake_seconds > 0)";
    "ts:path_bytes" = "rate(tailscaled_inbound_bytes_total[1m])";
    "wg:handshake_age_seconds" = "time() - wireguard_peer_latest_handshake_seconds";
    "wg:rx_bytes" = "rate(wireguard_peer_rx_bytes_total[1m])";
    "wg:tx_bytes" = "rate(wireguard_peer_tx_bytes_total[1m])";
  };

  # Peaks must descend through max_over_time at every hop, never through the mean,
  # or two downsampling passes average them away.
  aggregations = {
    avg = "avg_over_time";
    max = "max_over_time";
    min = "min_over_time";
  };

  downsampled = {
    temp_celsius = {
      source = "sensor:temp_celsius";
      aggs = [
        "avg"
        "max"
        "min"
      ];
    };
    fan_rpm = {
      source = "fan:rpm";
      aggs = [
        "avg"
        "max"
      ];
    };
    major_temp_celsius = {
      source = "temp:major_celsius";
      aggs = [
        "avg"
        "max"
        "min"
      ];
    };
    sensor_power_watt = {
      source = "sensor:power_watt";
      aggs = [
        "avg"
        "max"
      ];
    };
    volts = {
      source = "sensor:volts";
      aggs = [
        "avg"
        "min"
      ];
    };
    pc_power_watts = {
      source = "pc:power_watts";
      aggs = [
        "avg"
        "max"
        "min"
      ];
    };
    pc_cpu_power_watts = {
      source = "pc:cpu_power_watts";
      aggs = [
        "avg"
        "max"
      ];
    };
    pc_platform_power_watts = {
      source = "pc:platform_power_watts";
      aggs = [
        "avg"
        "max"
      ];
    };
    pi_pmic_rail_watts = {
      source = "pi:pmic_rail_watts";
      aggs = [
        "avg"
        "max"
      ];
    };
    laptop_battery_power_watts = {
      source = "laptop_battery_power_watts";
      aggs = [
        "avg"
        "max"
      ];
    };
    laptop_battery_energy_watt_hours = {
      source = "laptop_battery_energy_watt_hours";
      aggs = [ "avg" ];
    };
    laptop_battery_health_ratio = {
      source = "laptop_battery_health_ratio";
      aggs = [ "avg" ];
    };
    pc_gpu_power_watts = {
      source = "pc:gpu_power_watts";
      aggs = [
        "avg"
        "max"
      ];
    };
    pc_power_component_watts = {
      source = "pc:power_component_watts";
      aggs = [
        "avg"
        "max"
      ];
    };
    pc_supply_efficiency = {
      source = "pc:supply_efficiency";
      aggs = [ "avg" ];
    };
    pc_power_meter_watts = {
      source = "pc:power_meter_watts";
      aggs = [
        "avg"
        "max"
      ];
    };
    pc_power_model_error_watts = {
      source = "pc:power_model_error_watts";
      aggs = [ "avg" ];
    };
    pc_disk_standby = {
      source = "pc:disk_standby";
      aggs = [ "avg" ];
    };
    tariff_gbp_per_kwh = {
      source = "pc:tariff_gbp_per_kwh";
      aggs = [ "max" ];
    };
    cpu_utilisation = {
      source = "cpu:utilisation";
      aggs = [
        "avg"
        "max"
      ];
    };
    cpu_hertz = {
      source = "cpu:hertz";
      aggs = [
        "avg"
        "max"
      ];
    };
    cpu_hertz_min = {
      source = "cpu:hertz_min";
      aggs = [ "min" ];
    };
    cpu_hertz_max = {
      source = "cpu:hertz_max";
      aggs = [ "max" ];
    };
    cpu_throttled_ratio = {
      source = "cpu:throttled_ratio";
      aggs = [ "avg" ];
    };
    mem_used_bytes = {
      source = "mem:used_bytes";
      aggs = [
        "avg"
        "max"
      ];
    };
    mem_used_ratio = {
      source = "mem:used_ratio";
      aggs = [
        "avg"
        "max"
      ];
    };
    mem_cached_bytes = {
      source = "mem:cached_bytes";
      aggs = [ "avg" ];
    };
    mem_swap_used_bytes = {
      source = "mem:swap_used_bytes";
      aggs = [
        "avg"
        "max"
      ];
    };
    mem_total_bytes = {
      source = "mem:total_bytes";
      aggs = [ "max" ];
    };
    mem_capacity_info = {
      source = "mem:capacity_info";
      aggs = [ "max" ];
    };
    mem_swap_total_bytes = {
      source = "mem:swap_total_bytes";
      aggs = [ "max" ];
    };
    fs_size_bytes = {
      source = "fs:size_bytes";
      aggs = [ "max" ];
    };
    cpu_cores = {
      source = "cpu:cores";
      aggs = [ "max" ];
    };
    load1 = {
      source = "load:load1";
      aggs = [
        "avg"
        "max"
      ];
    };
    load_pressure_ratio = {
      source = "load:pressure_ratio";
      aggs = [
        "avg"
        "max"
      ];
    };
    psi_cpu_waiting = {
      source = "psi:cpu_waiting";
      aggs = [
        "avg"
        "max"
      ];
    };
    psi_io_stalled = {
      source = "psi:io_stalled";
      aggs = [
        "avg"
        "max"
      ];
    };
    psi_memory_stalled = {
      source = "psi:memory_stalled";
      aggs = [
        "avg"
        "max"
      ];
    };
    disk_io_time = {
      source = "disk:io_time";
      aggs = [
        "avg"
        "max"
      ];
    };
    disk_read_bytes = {
      source = "disk:read_bytes";
      aggs = [
        "avg"
        "max"
      ];
    };
    disk_written_bytes = {
      source = "disk:written_bytes";
      aggs = [
        "avg"
        "max"
      ];
    };
    fs_avail_bytes = {
      source = "fs:avail_bytes";
      aggs = [ "min" ];
    };
    fs_free_ratio = {
      source = "fs:free_ratio";
      aggs = [ "min" ];
    };
    systemd_failed_units = {
      source = "systemd:failed_units";
      aggs = [ "max" ];
    };
    up = {
      source = "host:up";
      aggs = [ "avg" ];
    };
    boot_time_seconds = {
      source = "host:boot_time_seconds";
      aggs = [ "max" ];
    };
    awake_since_seconds = {
      source = "host:awake_since_seconds";
      aggs = [ "max" ];
    };
    net_receive_bytes = {
      source = "net:receive_bytes";
      aggs = [
        "avg"
        "max"
      ];
    };
    net_transmit_bytes = {
      source = "net:transmit_bytes";
      aggs = [
        "avg"
        "max"
      ];
    };
    net_receive_bytes_by_transport = {
      source = "net:receive_bytes_by_transport";
      aggs = [
        "avg"
        "max"
      ];
    };
    net_transmit_bytes_by_transport = {
      source = "net:transmit_bytes_by_transport";
      aggs = [
        "avg"
        "max"
      ];
    };
    net_receive_errors = {
      source = "net:receive_errors";
      aggs = [ "avg" ];
    };
    net_transmit_errors = {
      source = "net:transmit_errors";
      aggs = [ "avg" ];
    };
    net_receive_drops = {
      source = "net:receive_drops";
      aggs = [ "avg" ];
    };
    ts_peer_rx_bytes = {
      source = "ts:peer_rx_bytes";
      aggs = [
        "avg"
        "max"
      ];
    };
    ts_peer_tx_bytes = {
      source = "ts:peer_tx_bytes";
      aggs = [
        "avg"
        "max"
      ];
    };
    ts_peer_online = {
      source = "ts:peer_online";
      aggs = [ "avg" ];
    };
    ts_peer_direct = {
      source = "ts:peer_direct";
      aggs = [ "avg" ];
    };
    ts_handshake_age_seconds = {
      source = "ts:handshake_age_seconds";
      aggs = [ "max" ];
    };
    ts_path_bytes = {
      source = "ts:path_bytes";
      aggs = [ "avg" ];
    };
    wg_handshake_age_seconds = {
      source = "wg:handshake_age_seconds";
      aggs = [ "max" ];
    };
    wg_rx_bytes = {
      source = "wg:rx_bytes";
      aggs = [ "avg" ];
    };
    wg_tx_bytes = {
      source = "wg:tx_bytes";
      aggs = [ "avg" ];
    };
    grafana_alerts = {
      source = "GRAFANA_ALERTS";
      aggs = [ "max" ];
    };
  };

  toRules = lib.mapAttrsToList (
    record: expr: {
      inherit record expr;
    }
  );

  aggSuffix = agg: if agg == "avg" then "" else "_${agg}";

  rollup =
    window: sourceOf:
    lib.flatten (
      lib.mapAttrsToList (
        metric:
        { source, aggs, ... }:
        map (agg: {
          record = "${source}:${window}${aggSuffix agg}";
          expr = "${aggregations.${agg}}(${sourceOf metric agg}[${window}])";
        }) aggs
      ) downsampled
    );

  minuteRollup = rollup "1m" (metric: _agg: downsampled.${metric}.source);

  # Same aggregates as the rollups, but recorded under the names federation
  # would have relabelled them to, so a backfill can write straight into the
  # tier it repairs.
  repairRollup =
    window: sourceOf:
    lib.flatten (
      lib.mapAttrsToList (
        metric:
        { source, aggs, ... }:
        map (agg: {
          record = "${source}${aggSuffix agg}";
          expr = "${aggregations.${agg}}(${sourceOf metric agg}[${window}])";
        }) aggs
      ) downsampled
    );

  minuteRepair = repairRollup "1m" (metric: _agg: downsampled.${metric}.source);

  hourRepair = repairRollup "1h" (metric: agg: "${downsampled.${metric}.source}${aggSuffix agg}");

  # The hourly hop reads the matching minute aggregate, so maxima stay maxima.
  hourRollup = rollup "1h" (metric: agg: "${downsampled.${metric}.source}${aggSuffix agg}");
in

{
  hires = [
    {
      name = "sensors";
      interval = "1s";
      rules = toRules sensorRules ++ powerRules;
    }
    {
      name = "system";
      interval = "1s";
      rules = toRules (systemRules // networkRules);
    }
    {
      name = "capacity";
      interval = "5m";
      rules = toRules capacityRules;
    }
    {
      name = "downsample";
      interval = "1m";
      rules = minuteRollup;
    }
  ];

  minuteRepair = [
    {
      name = "downsample-repair";
      interval = "1m";
      rules = minuteRepair;
    }
  ];

  hourRepair = [
    {
      name = "hourly-repair";
      interval = "1h";
      rules = hourRepair;
    }
  ];

  hourly = [
    {
      name = "hourly";
      interval = "5m";
      rules = hourRollup;
    }
  ];

  alerts =
    let
      threshold =
        {
          uid,
          title,
          expr,
          value,
          for' ? "2m",
          severity ? "warning",
          summary,
          valueFormat ? "humanize",
        }:
        {
          inherit uid title;
          condition = "C";
          for = for';
          labels = { inherit severity; };
          annotations = {
            summary =
              "${summary} Current value: {{ ${valueFormat} $values.A.Value }}; threshold: > ${toString value}. "
              + (if for' == "0s" then "Fires immediately." else "Fires after ${for'}. ")
              + "{{ with $values.B }}Sustained for {{ humanizeDuration .Value }}.{{ else }}Tracking sustained duration.{{ end }}";
          };
          noDataState = "OK";
          execErrState = "OK";
          data = [
            {
              refId = "A";
              relativeTimeRange = {
                from = 600;
                to = 0;
              };
              datasourceUid = "prometheus";
              model = {
                refId = "A";
                instant = true;
                expr = ''label_replace((${expr}), "alert_uid", "${uid}", "", "")'';
              };
            }
            {
              refId = "B";
              relativeTimeRange = {
                from = 600;
                to = 0;
              };
              datasourceUid = "prometheus";
              model = {
                refId = "B";
                instant = true;
                expr = ''time() - grafana_alert_sustained_since_seconds{alert_uid="${uid}"}'';
              };
            }
            {
              refId = "C";
              datasourceUid = "__expr__";
              model = {
                refId = "C";
                type = "threshold";
                expression = "A";
                conditions = [
                  {
                    evaluator = {
                      type = "gt";
                      params = [ value ];
                    };
                  }
                ];
              };
            }
          ];
        };
      logThreshold =
        {
          uid,
          title,
          expr,
          summary,
          severity ? "warning",
        }:
        {
          inherit uid title;
          condition = "C";
          for = "0s";
          labels = { inherit severity; };
          annotations = {
            summary =
              "${summary} Fires immediately. "
              + "{{ with $values.B }}Sustained for {{ humanizeDuration .Value }}.{{ else }}Tracking sustained duration.{{ end }}";
          };
          noDataState = "OK";
          execErrState = "OK";
          data = [
            {
              refId = "A";
              relativeTimeRange = {
                from = 300;
                to = 0;
              };
              datasourceUid = "loki";
              model = {
                refId = "A";
                expr = expr;
                editorMode = "code";
                queryType = "instant";
                instant = true;
                datasource = {
                  type = "loki";
                  uid = "loki";
                };
              };
            }
            {
              refId = "B";
              relativeTimeRange = {
                from = 300;
                to = 0;
              };
              datasourceUid = "prometheus";
              model = {
                refId = "B";
                instant = true;
                expr = ''time() - grafana_alert_sustained_since_seconds{alert_uid="${uid}"}'';
              };
            }
            {
              refId = "C";
              datasourceUid = "__expr__";
              model = {
                refId = "C";
                type = "threshold";
                expression = "A";
                conditions = [
                  {
                    evaluator = {
                      type = "gt";
                      params = [ 0 ];
                    };
                  }
                ];
              };
            }
          ];
        };
    in
    [
      (threshold {
        uid = "cpu-temp-high";
        title = "CPU temperature high";
        expr = ''temp:major_celsius{component="CPU"}'';
        value = cfg.alerts.cpuTempCelsius;
        summary = "CPU is above {{ $labels.instance }}'s warning threshold.";
      })
      (threshold {
        uid = "cpu-temp-critical";
        title = "CPU temperature critical";
        expr = ''temp:major_celsius{component="CPU"}'';
        value = cfg.alerts.cpuCriticalCelsius;
        for' = "1m";
        severity = "critical";
        summary = "CPU on {{ $labels.instance }} is close to thermal shutdown.";
      })
      (threshold {
        uid = "ccd-temp-high";
        title = "CPU die temperature high";
        expr = ''sensor:temp_celsius{name=~"CPU CCD.*|Tccd.*"}'';
        value = cfg.alerts.cpuCriticalCelsius - 5;
        summary = "{{ $labels.name }} on {{ $labels.instance }} is running hot.";
        valueFormat = "humanize";
      })
      (threshold {
        uid = "gpu-temp-high";
        title = "GPU temperature high";
        expr = ''temp:major_celsius{component="GPU"}'';
        value = cfg.alerts.gpuTempCelsius;
        summary = "GPU on {{ $labels.instance }} is running hot.";
      })
      (threshold {
        uid = "nvme-temp-high";
        title = "NVMe temperature high";
        expr = ''temp:major_celsius{component="Storage"}'';
        value = cfg.alerts.nvmeTempCelsius;
        for' = "5m";
        summary = "NVMe on {{ $labels.instance }} is above its comfortable range.";
      })
      (threshold {
        uid = "drive-temp-high";
        title = "Disk temperature high";
        expr = ''sensor:temp_celsius{name=~"HDD.*"}'';
        value = cfg.alerts.driveTempCelsius;
        for' = "10m";
        summary = "{{ $labels.name }} on {{ $labels.instance }} is above its comfortable range.";
      })
      (threshold {
        uid = "vrm-temp-high";
        title = "VRM temperature high";
        expr = ''sensor:temp_celsius{name=~"VRM.*|VSoC.*"}'';
        value = cfg.alerts.vrmTempCelsius;
        summary = "{{ $labels.name }} on {{ $labels.instance }} is running hot.";
      })
      (threshold {
        uid = "fan-stalled-while-hot";
        title = "Fan stopped while hot";
        expr =
          "count by (instance, id, name) (fan:rpm == 0) and "
          + ''on(instance) (temp:major_celsius{component="CPU"} > 60)'';
        value = 0;
        for' = "3m";
        severity = "critical";
        summary = "{{ $labels.name }} ({{ $labels.id }}) on {{ $labels.instance }} reads zero RPM while the machine is hot.";
      })
      (threshold {
        uid = "total-power-high";
        title = "Total power draw high";
        expr = "max by (instance) (pc:power_watts)";
        value = cfg.alerts.powerWatts;
        for' = "10m";
        summary = "{{ $labels.instance }} has been drawing an unusual amount of power.";
      })
      (threshold {
        uid = "host-down";
        title = "Host down";
        expr =
          "clamp_min((1 - max by (instance) (host:up))"
          + ''- (clamp_max(max by (instance) (host_power_state{state=~"S3|S5"}), 1)''
          + "or (0 * max by (instance) (host:up))), 0)";
        value = 0;
        for' = "5m";
        summary = "{{ $labels.instance }} has stopped responding to scrapes.";
      })
      (threshold {
        uid = "filesystem-low";
        title = "Filesystem nearly full";
        expr = "1 - min by (instance, mountpoint) (fs:free_ratio)";
        value = 1 - cfg.alerts.filesystemFreeRatio;
        for' = "15m";
        summary = "{{ $labels.mountpoint }} on {{ $labels.instance }} is nearly full.";
      })
      (threshold {
        uid = "peer-offline";
        title = "Tailnet peer offline";
        expr = "max by (peer) (ts:handshake_age_seconds)";
        value = 900;
        for' = "5m";
        summary = "{{ $labels.peer }} has not handshaken recently.";
      })
      (threshold {
        uid = "systemd-units-failed";
        title = "Failed systemd units";
        expr = ''max by (instance, name) (node_systemd_unit_state{state="failed"})'';
        value = 0;
        for' = "5m";
        summary = "{{ $labels.name }} has failed on {{ $labels.instance }}.";
      })
      (threshold {
        uid = "cpu-pressure-warning";
        title = "Sustained CPU pressure";
        expr = "max by (instance) (psi:cpu_waiting)";
        value = 0.1;
        for' = "5m";
        summary = "CPU work on {{ $labels.instance }} has spent over 10% of its time waiting.";
        valueFormat = "humanizePercentage";
      })
      (threshold {
        uid = "cpu-pressure-critical";
        title = "Severe CPU pressure";
        expr = "max by (instance) (psi:cpu_waiting)";
        value = 0.5;
        for' = "10m";
        severity = "critical";
        summary = "CPU work on {{ $labels.instance }} has spent over half its time waiting.";
        valueFormat = "humanizePercentage";
      })
      (threshold {
        uid = "io-pressure-warning";
        title = "Sustained I/O pressure";
        expr = "max by (instance) (psi:io_stalled)";
        value = 0.02;
        for' = "5m";
        summary = "Tasks on {{ $labels.instance }} are repeatedly fully stalled on I/O.";
        valueFormat = "humanizePercentage";
      })
      (threshold {
        uid = "io-pressure-critical";
        title = "Severe I/O pressure";
        expr = "max by (instance) (psi:io_stalled)";
        value = 0.15;
        for' = "10m";
        severity = "critical";
        summary = "Tasks on {{ $labels.instance }} are severely stalled on I/O.";
        valueFormat = "humanizePercentage";
      })
      (threshold {
        uid = "memory-pressure-warning";
        title = "Sustained memory pressure";
        expr = "max by (instance) (psi:memory_stalled)";
        value = 0.01;
        for' = "3m";
        summary = "Tasks on {{ $labels.instance }} are repeatedly fully stalled on memory.";
        valueFormat = "humanizePercentage";
      })
      (threshold {
        uid = "memory-pressure-critical";
        title = "Severe memory pressure";
        expr = "max by (instance) (psi:memory_stalled)";
        value = 0.05;
        for' = "5m";
        severity = "critical";
        summary = "Tasks on {{ $labels.instance }} are severely stalled on memory.";
        valueFormat = "humanizePercentage";
      })
      (threshold {
        uid = "network-errors";
        title = "Sustained network errors";
        expr = "sum by (instance, device) (net:receive_errors + net:transmit_errors)";
        value = 0.1;
        for' = "5m";
        summary = "{{ $labels.device }} on {{ $labels.instance }} is reporting sustained packet errors.";
      })
      (threshold {
        uid = "network-drops";
        title = "Sustained network drops";
        expr = "sum by (instance, device) (net:receive_drops)";
        value = 1;
        for' = "5m";
        summary = "{{ $labels.device }} on {{ $labels.instance }} is dropping packets persistently.";
      })
      (threshold {
        uid = "tailnet-relayed";
        title = "Tailnet peer stuck on DERP";
        expr = "max by (instance, peer) (ts:peer_online * (1 - ts:peer_direct))";
        value = 0;
        for' = "10m";
        summary = "Traffic from {{ $labels.instance }} to {{ $labels.peer }} has remained relayed for ten minutes.";
      })
      (logThreshold {
        uid = "nix-rebuild-failed";
        title = "Nix rebuild failed";
        expr = ''sum by (host, project, failed_package, trace_id, alert_uid) (count_over_time({service_name="nix-observer-summary"} | json | label_format alert_uid="nix-rebuild-failed" | event="nix_build" | status="failed" | alert_eligible="true" [5m]))'';
        severity = "critical";
        summary = "{{ $labels.project }} failed on {{ $labels.host }} at {{ $labels.failed_package }} (trace {{ $labels.trace_id }}).";
      })
    ];
}

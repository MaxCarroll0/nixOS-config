# Grafana dashboards, one folder per Prometheus tier.

{ lib }:

let
  target =
    {
      expr,
      legend ? "",
      interval ? null,
      format ? "time_series",
      instant ? false,
    }:
    {
      inherit expr instant;
      legendFormat = legend;
      editorMode = "code";
      range = !instant;
      format = format;
    }
    // lib.optionalAttrs (interval != null) { inherit interval; };

  withRefIds = lib.imap0 (i: t: t // { refId = lib.elemAt lib.strings.upperChars i; });

  panel =
    type:
    {
      title,
      w ? 12,
      h ? 8,
      unit ? "short",
      targets ? [ ],
      description ? null,
      options ? { },
      custom ? { },
      overrides ? [ ],
      mappings ? [ ],
      max ? null,
      min ? null,
      decimals ? null,
      transformations ? [ ],
    }:
    {
      inherit
        type
        title
        w
        h
        options
        transformations
        ;
      targets = withRefIds targets;
      fieldConfig = {
        defaults = {
          inherit unit mappings;
          custom = custom;
        }
        // lib.optionalAttrs (max != null) { inherit max; }
        // lib.optionalAttrs (min != null) { inherit min; }
        // lib.optionalAttrs (decimals != null) { inherit decimals; };
        inherit overrides;
      };
    }
    // lib.optionalAttrs (description != null) { inherit description; };

  lineCustom = {
    lineWidth = 2;
    fillOpacity = 6;
    showPoints = "never";
    lineInterpolation = "smooth";
  };

  legendOptions = {
    legend = {
      displayMode = "table";
      placement = "bottom";
      showLegend = true;
      calcs = [
        "lastNotNull"
        "max"
      ];
    };
    tooltip.mode = "multi";
    tooltip.sort = "desc";
  };

  statOptions = {
    reduceOptions = {
      calcs = [ "lastNotNull" ];
      fields = "";
      values = false;
    };
    textMode = "auto";
    colorMode = "value";
    graphMode = "area";
  };

  ts =
    args:
    panel "timeseries" (
      {
        custom = lineCustom;
        options = legendOptions;
      }
      // args
    );
  stat = args: panel "stat" ({ options = statOptions; } // args);
  bar =
    args:
    panel "barchart" (
      {
        options = legendOptions // {
          xTickLabelRotation = -45;
        };
        custom = {
          fillOpacity = 80;
          lineWidth = 1;
        };
      }
      // args
    );
  table = args: panel "table" args;
  timeline =
    args:
    panel "state-timeline" (
      {
        options = {
          showValue = "never";
          mergeValues = true;
        };
      }
      // args
    );
  xy = args: panel "xychart" args;

  rightAxis = pattern: {
    matcher = {
      id = "byRegexp";
      options = pattern;
    };
    properties = [
      {
        id = "custom.axisPlacement";
        value = "right";
      }
      {
        id = "unit";
        value = "rotrpm";
      }
      {
        id = "custom.fillOpacity";
        value = 0;
      }
    ];
  };

  dimmed = pattern: {
    matcher = {
      id = "byRegexp";
      options = pattern;
    };
    properties = [
      {
        id = "custom.fillOpacity";
        value = 0;
      }
      {
        id = "custom.lineWidth";
        value = 1;
      }
      {
        id = "custom.lineStyle";
        value = {
          fill = "dash";
          dash = [
            6
            6
          ];
        };
      }
    ];
  };

  upMappings = [
    {
      type = "value";
      options = {
        "0".text = "Down";
        "0".color = "red";
        "1".text = "Up";
        "1".color = "green";
      };
    }
  ];

  directMappings = [
    {
      type = "value";
      options = {
        "0".text = "Relayed";
        "0".color = "orange";
        "1".text = "Direct";
        "1".color = "green";
      };
    }
  ];

  # Greedy row packing: panels keep their declared width and wrap at 24 columns.
  layout =
    panels:
    (lib.foldl'
      (
        acc: p:
        let
          wraps = acc.cursor + p.w > 24;
          x = if wraps then 0 else acc.cursor;
          y = if wraps then acc.y + acc.rowHeight else acc.y;
        in
        {
          cursor = x + p.w;
          inherit y;
          rowHeight = if wraps then p.h else lib.max acc.rowHeight p.h;
          placed = acc.placed ++ [
            (
              (removeAttrs p [
                "w"
                "h"
              ])
              // {
                gridPos = {
                  inherit x y;
                  inherit (p) w h;
                };
              }
            )
          ];
        }
      )
      {
        cursor = 0;
        y = 0;
        rowHeight = 0;
        placed = [ ];
      }
      panels
    ).placed;

  smoothVariable = {
    name = "smooth";
    label = "Smoothing";
    type = "interval";
    auto = false;
    query = "5m,15m,1h,6h,1d";
    current = {
      text = "15m";
      value = "15m";
    };
    options =
      map
        (v: {
          text = v;
          value = v;
          selected = v == "15m";
        })
        [
          "5m"
          "15m"
          "1h"
          "6h"
          "1d"
        ];
  };

  dashboard =
    {
      uid,
      title,
      datasource,
      from,
      refresh,
      panels,
      variables ? [ ],
      tags ? [ ],
    }:
    let
      ds = {
        type = "prometheus";
        uid = datasource;
      };
      attach =
        p:
        p
        // {
          datasource = ds;
          targets = map (t: t // { datasource = ds; }) (p.targets or [ ]);
        };
    in
    {
      inherit
        uid
        title
        refresh
        tags
        ;
      schemaVersion = 39;
      timezone = "browser";
      editable = false;
      time = {
        inherit from;
        to = "now";
      };
      templating.list = variables;
      panels = lib.imap1 (i: p: attach (p // { id = i; })) (layout panels);
    };

  # Live folder: raw 1-second series, nothing smoothed.

  livePower = dashboard {
    uid = "live-power";
    title = "Power and thermals (live)";
    datasource = "prometheus";
    from = "now-15m";
    refresh = "1s";
    tags = [ "live" ];
    panels = [
      (stat {
        title = "Total draw";
        w = 6;
        h = 5;
        unit = "watt";
        decimals = 0;
        targets = [
          (target {
            expr = "pc:power_watts";
            legend = "{{instance}}";
          })
        ];
      })
      (stat {
        title = "CPU";
        w = 6;
        h = 5;
        unit = "watt";
        decimals = 0;
        targets = [
          (target {
            expr = "pc:cpu_power_watts";
            legend = "{{instance}}";
          })
        ];
      })
      (stat {
        title = "GPU";
        w = 6;
        h = 5;
        unit = "watt";
        decimals = 0;
        targets = [
          (target {
            expr = "pc:gpu_power_watts";
            legend = "{{instance}}";
          })
        ];
      })
      (stat {
        title = "CPU temperature";
        w = 6;
        h = 5;
        unit = "celsius";
        decimals = 0;
        targets = [
          (target {
            expr = ''max by (instance) (sensor:temp_celsius{name=~"CPU Tctl|CPU Tdie"})'';
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Total PC power, broken down";
        description = "Modelled, not measured: this board has no PSU telemetry. CPU comes from zenpower's SVI2 rails when present and RAPL otherwise, GPU from the amdgpu board sensor, and the baseline is the configured allowance for RAM, drives, fans and board. The sum is divided by the assumed PSU efficiency to give an estimate at the wall.";
        w = 24;
        h = 9;
        unit = "watt";
        custom = lineCustom // {
          stacking = {
            mode = "normal";
            group = "A";
          };
          fillOpacity = 35;
        };
        targets = [
          (target {
            expr = "pc:cpu_power_watts";
            legend = "{{instance}} CPU";
          })
          (target {
            expr = "pc:gpu_power_watts";
            legend = "{{instance}} GPU";
          })
          (target {
            expr = "pc:baseline_watts";
            legend = "{{instance}} baseline";
          })
        ];
      })
      (ts {
        title = "Temperatures";
        unit = "celsius";
        targets = [
          (target {
            expr = "sensor:temp_celsius";
            legend = "{{instance}} {{name}}";
          })
        ];
      })
      (ts {
        title = "Fan speed";
        unit = "rotrpm";
        targets = [
          (target {
            expr = "sensor:fan_rpm";
            legend = "{{instance}} {{name}}";
          })
        ];
      })
      (ts {
        title = "Temperature against fan speed";
        description = "Fans on the right axis. At one-second resolution the lag between a temperature rise and the fan responding is visible directly.";
        w = 24;
        h = 9;
        unit = "celsius";
        overrides = [ (rightAxis ".*rpm.*") ];
        targets = [
          (target {
            expr = "sensor:temp_celsius";
            legend = "{{instance}} {{name}}";
          })
          (target {
            expr = "sensor:fan_rpm";
            legend = "{{instance}} {{name}} rpm";
          })
        ];
      })
      (ts {
        title = "CPU frequency";
        unit = "hertz";
        targets = [
          (target {
            expr = "node_cpu_scaling_frequency_hertz";
            legend = "{{instance}} cpu{{cpu}}";
          })
        ];
      })
      (ts {
        title = "Sensor power rails";
        unit = "watt";
        targets = [
          (target {
            expr = "sensor:power_watt";
            legend = "{{instance}} {{name}}";
          })
        ];
      })
      (ts {
        title = "Voltages";
        description = "Populated only if the it87 Super I/O driver probes this board.";
        unit = "volt";
        targets = [
          (target {
            expr = "sensor:volts";
            legend = "{{instance}} {{name}}";
          })
        ];
      })
      (ts {
        title = "Fan PWM duty";
        unit = "percent";
        max = 100;
        min = 0;
        targets = [
          (target {
            expr = "sensor:pwm_percent";
            legend = "{{instance}} {{name}}";
          })
        ];
      })
    ];
  };

  liveSystem = dashboard {
    uid = "live-system";
    title = "System (live)";
    datasource = "prometheus";
    from = "now-15m";
    refresh = "1s";
    tags = [ "live" ];
    panels = [
      (ts {
        title = "CPU utilisation";
        unit = "percentunit";
        max = 1;
        min = 0;
        targets = [
          (target {
            expr = "cpu:utilisation";
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "CPU utilisation per core";
        unit = "percentunit";
        max = 1;
        min = 0;
        targets = [
          (target {
            expr = ''1 - rate(node_cpu_seconds_total{mode="idle"}[5s])'';
            legend = "{{instance}} cpu{{cpu}}";
          })
        ];
      })
      (stat {
        title = "RAM installed";
        w = 6;
        h = 5;
        unit = "bytes";
        decimals = 0;
        targets = [
          (target {
            expr = "mem:total_bytes";
            legend = "{{instance}}";
          })
        ];
      })
      (stat {
        title = "RAM in use";
        w = 6;
        h = 5;
        unit = "percentunit";
        max = 1;
        min = 0;
        targets = [
          (target {
            expr = "mem:used_ratio";
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Memory";
        description = "Used excludes reclaimable cache, so it tracks what the machine actually needs. The dashed line is installed capacity.";
        w = 12;
        h = 8;
        unit = "bytes";
        min = 0;
        overrides = [ (dimmed ".*(capacity|cache)$") ];
        targets = [
          (target {
            expr = "mem:used_bytes";
            legend = "{{instance}} used";
          })
          (target {
            expr = "mem:cached_bytes";
            legend = "{{instance}} cache";
          })
          (target {
            expr = "mem:total_bytes";
            legend = "{{instance}} capacity";
          })
        ];
      })
      (ts {
        title = "Swap used";
        unit = "bytes";
        min = 0;
        targets = [
          (target {
            expr = "mem:swap_used_bytes";
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Pressure stall";
        description = "The share of time work was stalled waiting on a resource. Catches contention that CPU utilisation alone hides.";
        unit = "percentunit";
        targets = [
          (target {
            expr = "psi:cpu_waiting";
            legend = "{{instance}} cpu";
          })
          (target {
            expr = "psi:io_stalled";
            legend = "{{instance}} io";
          })
          (target {
            expr = "psi:memory_stalled";
            legend = "{{instance}} memory";
          })
        ];
      })
      (ts {
        title = "Disk throughput";
        unit = "Bps";
        targets = [
          (target {
            expr = "disk:read_bytes";
            legend = "{{instance}} {{device}} read";
          })
          (target {
            expr = "disk:written_bytes";
            legend = "{{instance}} {{device}} write";
          })
        ];
      })
      (ts {
        title = "Disk busy";
        unit = "percentunit";
        targets = [
          (target {
            expr = "disk:io_time";
            legend = "{{instance}} {{device}}";
          })
        ];
      })
      (ts {
        title = "Network throughput";
        unit = "Bps";
        targets = [
          (target {
            expr = "net:receive_bytes";
            legend = "{{instance}} {{device}} in";
          })
          (target {
            expr = "net:transmit_bytes";
            legend = "{{instance}} {{device}} out";
          })
        ];
      })
      (ts {
        title = "Load average";
        targets = [
          (target {
            expr = "load:load1";
            legend = "{{instance}}";
          })
        ];
      })
    ];
  };

  # History folder: 1-minute aggregates, smoothed by the $smooth variable.

  historyPower = dashboard {
    uid = "history-power";
    title = "Power and thermals";
    datasource = "prometheus-lt";
    from = "now-7d";
    refresh = "1m";
    tags = [ "history" ];
    variables = [ smoothVariable ];
    panels = [
      (stat {
        title = "Mean draw";
        w = 6;
        h = 5;
        unit = "watt";
        decimals = 0;
        targets = [
          (target {
            expr = "avg_over_time(avg1m:pc_power_watts[$__range])";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (stat {
        title = "Peak draw";
        w = 6;
        h = 5;
        unit = "watt";
        decimals = 0;
        targets = [
          (target {
            expr = "max_over_time(max1m:pc_power_watts[$__range])";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (stat {
        title = "Energy";
        w = 6;
        h = 5;
        unit = "kwatth";
        decimals = 1;
        targets = [
          (target {
            expr = "sum_over_time(avg1m:pc_power_watts[$__range]) / 60 / 1000";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (stat {
        title = "Cost";
        w = 6;
        h = 5;
        unit = "currencyGBP";
        decimals = 2;
        targets = [
          (target {
            expr = "sum_over_time(avg1m:pc_power_watts[$__range]) / 60 / 1000 * on(instance) group_left() max1m:tariff_gbp_per_kwh";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (ts {
        title = "Total PC power";
        description = "Solid line is the smoothed mean; dashed lines are the true per-minute maximum and minimum, so peaks survive whatever smoothing window is selected.";
        w = 24;
        h = 9;
        unit = "watt";
        overrides = [ (dimmed ".*(peak|floor)$") ];
        targets = [
          (target {
            expr = "avg_over_time(avg1m:pc_power_watts[$smooth])";
            legend = "{{instance}}";
          })
          (target {
            expr = "max_over_time(max1m:pc_power_watts[$smooth])";
            legend = "{{instance}} peak";
          })
          (target {
            expr = "min_over_time(min1m:pc_power_watts[$smooth])";
            legend = "{{instance}} floor";
          })
        ];
      })
      (ts {
        title = "CPU against GPU power";
        unit = "watt";
        targets = [
          (target {
            expr = "avg_over_time(avg1m:pc_cpu_power_watts[$smooth])";
            legend = "{{instance}} CPU";
          })
          (target {
            expr = "avg_over_time(avg1m:pc_gpu_power_watts[$smooth])";
            legend = "{{instance}} GPU";
          })
        ];
      })
      (ts {
        title = "Temperatures";
        unit = "celsius";
        overrides = [ (dimmed ".*peak$") ];
        targets = [
          (target {
            expr = "avg_over_time(avg1m:temp_celsius[$smooth])";
            legend = "{{instance}} {{name}}";
          })
          (target {
            expr = "max_over_time(max1m:temp_celsius[$smooth])";
            legend = "{{instance}} {{name}} peak";
          })
        ];
      })
      (ts {
        title = "Temperature against fan speed";
        w = 24;
        h = 9;
        unit = "celsius";
        overrides = [ (rightAxis ".*rpm.*") ];
        targets = [
          (target {
            expr = "avg_over_time(avg1m:temp_celsius[$smooth])";
            legend = "{{instance}} {{name}}";
          })
          (target {
            expr = "avg_over_time(avg1m:fan_rpm[$smooth])";
            legend = "{{instance}} {{name}} rpm";
          })
        ];
      })
      (xy {
        title = "Fan speed against temperature";
        description = "Each point is one smoothing window. A fan curve that is holding temperature traces a tight band; a scattered cloud means the fan is not tracking the load.";
        w = 12;
        h = 9;
        unit = "celsius";
        options.mapping = "auto";
        transformations = [
          {
            id = "joinByField";
            options.byField = "Time";
          }
        ];
        targets = [
          (target {
            expr = "max by (instance) (avg_over_time(avg1m:fan_rpm[$smooth]))";
            legend = "{{instance}} fan";
          })
          (target {
            expr = "max by (instance) (avg_over_time(avg1m:temp_celsius[$smooth]))";
            legend = "{{instance}} temp";
          })
        ];
      })
      (table {
        title = "Temperature summary";
        w = 12;
        h = 9;
        unit = "celsius";
        decimals = 1;
        transformations = [
          {
            id = "reduce";
            options.reducers = [
              "mean"
              "max"
              "min"
              "lastNotNull"
            ];
          }
        ];
        targets = [
          (target {
            expr = "avg_over_time(avg1m:temp_celsius[$smooth])";
            legend = "{{instance}} {{name}}";
          })
        ];
      })
    ];
  };

  historyNetwork = dashboard {
    uid = "history-network";
    title = "Network and tailnet";
    datasource = "prometheus-lt";
    from = "now-7d";
    refresh = "1m";
    tags = [ "history" ];
    variables = [ smoothVariable ];
    panels = [
      (ts {
        title = "Interface throughput";
        w = 24;
        h = 9;
        unit = "Bps";
        targets = [
          (target {
            expr = "avg_over_time(avg1m:net_receive_bytes[$smooth])";
            legend = "{{instance}} {{device}} in";
          })
          (target {
            expr = "avg_over_time(avg1m:net_transmit_bytes[$smooth])";
            legend = "{{instance}} {{device}} out";
          })
        ];
      })
      (table {
        title = "Tailnet source map";
        description = "Directed traffic between tailnet nodes: each row is one host's send rate to one peer. Byte counters reset when tailscaled restarts, which the rate() underneath handles.";
        w = 12;
        h = 9;
        unit = "Bps";
        transformations = [
          {
            id = "organize";
            options.renameByName = {
              instance = "From";
              peer = "To";
              relay = "Relay";
              Value = "Throughput";
            };
            options.excludeByName = {
              Time = true;
              __name__ = true;
              job = true;
              peer_os = true;
            };
          }
          {
            id = "sortBy";
            options.sort = [
              {
                field = "Throughput";
                desc = true;
              }
            ];
          }
        ];
        targets = [
          (target {
            expr = "avg_over_time(avg1m:ts_peer_tx_bytes[$smooth])";
            format = "table";
            instant = true;
          })
        ];
      })
      (ts {
        title = "Per-peer throughput";
        w = 12;
        h = 9;
        unit = "Bps";
        targets = [
          (target {
            expr = "avg_over_time(avg1m:ts_peer_tx_bytes[$smooth])";
            legend = "{{instance}} to {{peer}}";
          })
          (target {
            expr = "avg_over_time(avg1m:ts_peer_rx_bytes[$smooth])";
            legend = "{{instance}} from {{peer}}";
          })
        ];
      })
      (ts {
        title = "Direct against relayed tailnet traffic";
        description = "A rising DERP share means peers stopped reaching each other directly.";
        unit = "Bps";
        targets = [
          (target {
            expr = "avg_over_time(avg1m:ts_path_bytes[$smooth])";
            legend = "{{instance}} {{path}}";
          })
        ];
      })
      (timeline {
        title = "Peer connection type";
        mappings = directMappings;
        targets = [
          (target {
            expr = "avg_over_time(avg1m:ts_peer_direct[$smooth])";
            legend = "{{instance}} to {{peer}}";
          })
        ];
      })
      (ts {
        title = "Interface errors and drops";
        unit = "pps";
        targets = [
          (target {
            expr = "avg_over_time(avg1m:net_receive_errors[$smooth])";
            legend = "{{instance}} {{device}} rx errors";
          })
          (target {
            expr = "avg_over_time(avg1m:net_transmit_errors[$smooth])";
            legend = "{{instance}} {{device}} tx errors";
          })
          (target {
            expr = "avg_over_time(avg1m:net_receive_drops[$smooth])";
            legend = "{{instance}} {{device}} drops";
          })
        ];
      })
      (ts {
        title = "WireGuard handshake age";
        description = "A tunnel can be up and still pass no return traffic. Handshake age climbing while bytes flow one way is the signature of two hosts sharing one Proton credential.";
        unit = "s";
        targets = [
          (target {
            expr = "max_over_time(max1m:wg_handshake_age_seconds[$smooth])";
            legend = "{{instance}} {{interface}}";
          })
        ];
      })
      (ts {
        title = "WireGuard throughput";
        unit = "Bps";
        targets = [
          (target {
            expr = "avg_over_time(avg1m:wg_rx_bytes[$smooth])";
            legend = "{{instance}} {{interface}} in";
          })
          (target {
            expr = "avg_over_time(avg1m:wg_tx_bytes[$smooth])";
            legend = "{{instance}} {{interface}} out";
          })
        ];
      })
    ];
  };

  historyFleet = dashboard {
    uid = "history-fleet";
    title = "Fleet and connectivity";
    datasource = "prometheus-lt";
    from = "now-7d";
    refresh = "1m";
    tags = [ "history" ];
    variables = [ smoothVariable ];
    panels = [
      (stat {
        title = "Hosts up";
        w = 6;
        h = 5;
        targets = [
          (target {
            expr = "count(avg1m:up == 1)";
            instant = true;
          })
        ];
      })
      (stat {
        title = "Peers online";
        w = 6;
        h = 5;
        targets = [
          (target {
            expr = "count(max by (peer) (avg1m:ts_peer_online) == 1)";
            instant = true;
          })
        ];
      })
      (stat {
        title = "Uptime";
        w = 12;
        h = 5;
        unit = "s";
        decimals = 1;
        targets = [
          (target {
            expr = "time() - max by (instance) (max1m:boot_time_seconds)";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (table {
        title = "Devices";
        w = 12;
        h = 9;
        mappings = upMappings;
        transformations = [
          {
            id = "organize";
            options.renameByName = {
              peer = "Device";
              peer_os = "OS";
              relay = "Relay";
              Value = "Online";
            };
            options.excludeByName = {
              Time = true;
              __name__ = true;
              job = true;
              instance = true;
            };
          }
        ];
        targets = [
          (target {
            expr = "max by (peer, peer_os, relay) (avg1m:ts_peer_online)";
            format = "table";
            instant = true;
          })
        ];
      })
      (table {
        title = "Last handshake";
        w = 12;
        h = 9;
        unit = "s";
        transformations = [
          {
            id = "organize";
            options.renameByName = {
              peer = "Device";
              Value = "Age";
            };
            options.excludeByName = {
              Time = true;
              __name__ = true;
              job = true;
              instance = true;
              peer_os = true;
              relay = true;
            };
          }
        ];
        targets = [
          (target {
            expr = "max by (peer) (max1m:ts_handshake_age_seconds)";
            format = "table";
            instant = true;
          })
        ];
      })
      (timeline {
        title = "Host reachability";
        w = 24;
        h = 8;
        mappings = upMappings;
        targets = [
          (target {
            expr = "avg1m:up";
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Uptime";
        w = 24;
        h = 8;
        unit = "s";
        targets = [
          (target {
            expr = "time() - max by (instance) (max1m:boot_time_seconds)";
            legend = "{{instance}}";
          })
        ];
      })
    ];
  };

  historySystem = dashboard {
    uid = "history-system";
    title = "System health";
    datasource = "prometheus-lt";
    from = "now-7d";
    refresh = "1m";
    tags = [ "history" ];
    variables = [ smoothVariable ];
    panels = [
      (ts {
        title = "CPU utilisation";
        unit = "percentunit";
        max = 1;
        min = 0;
        overrides = [ (dimmed ".*peak$") ];
        targets = [
          (target {
            expr = "avg_over_time(avg1m:cpu_utilisation[$smooth])";
            legend = "{{instance}}";
          })
          (target {
            expr = "max_over_time(max1m:cpu_utilisation[$smooth])";
            legend = "{{instance}} peak";
          })
        ];
      })
      (ts {
        title = "Load average";
        targets = [
          (target {
            expr = "avg_over_time(avg1m:load1[$smooth])";
            legend = "{{instance}}";
          })
        ];
      })
      (stat {
        title = "RAM installed";
        w = 6;
        h = 5;
        unit = "bytes";
        decimals = 0;
        targets = [
          (target {
            expr = "max1m:mem_total_bytes";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (stat {
        title = "Peak RAM used";
        w = 6;
        h = 5;
        unit = "percentunit";
        targets = [
          (target {
            expr = "max_over_time(max1m:mem_used_ratio[$__range])";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (ts {
        title = "Memory";
        description = "Solid is memory in use, dashed is installed capacity. Headroom is the gap between them.";
        w = 12;
        h = 8;
        unit = "bytes";
        min = 0;
        overrides = [ (dimmed ".*capacity$") ];
        targets = [
          (target {
            expr = "avg_over_time(avg1m:mem_used_bytes[$smooth])";
            legend = "{{instance}} used";
          })
          (target {
            expr = "max_over_time(max1m:mem_used_bytes[$smooth])";
            legend = "{{instance}} peak";
          })
          (target {
            expr = "max1m:mem_total_bytes";
            legend = "{{instance}} capacity";
          })
        ];
      })
      (ts {
        title = "Memory used";
        unit = "percentunit";
        max = 1;
        min = 0;
        overrides = [ (dimmed ".*peak$") ];
        targets = [
          (target {
            expr = "avg_over_time(avg1m:mem_used_ratio[$smooth])";
            legend = "{{instance}}";
          })
          (target {
            expr = "max_over_time(max1m:mem_used_ratio[$smooth])";
            legend = "{{instance}} peak";
          })
        ];
      })
      (ts {
        title = "Swap used";
        unit = "bytes";
        min = 0;
        overrides = [ (dimmed ".*capacity$") ];
        targets = [
          (target {
            expr = "avg_over_time(avg1m:mem_swap_used_bytes[$smooth])";
            legend = "{{instance}}";
          })
          (target {
            expr = "max1m:mem_swap_total_bytes";
            legend = "{{instance}} capacity";
          })
        ];
      })
      (ts {
        title = "Pressure stall";
        unit = "percentunit";
        targets = [
          (target {
            expr = "avg_over_time(avg1m:psi_cpu_waiting[$smooth])";
            legend = "{{instance}} cpu";
          })
          (target {
            expr = "avg_over_time(avg1m:psi_io_stalled[$smooth])";
            legend = "{{instance}} io";
          })
          (target {
            expr = "avg_over_time(avg1m:psi_memory_stalled[$smooth])";
            legend = "{{instance}} memory";
          })
        ];
      })
      (ts {
        title = "Disk throughput";
        unit = "Bps";
        targets = [
          (target {
            expr = "avg_over_time(avg1m:disk_read_bytes[$smooth])";
            legend = "{{instance}} {{device}} read";
          })
          (target {
            expr = "avg_over_time(avg1m:disk_written_bytes[$smooth])";
            legend = "{{instance}} {{device}} write";
          })
        ];
      })
      (ts {
        title = "Clock speed against its ceiling";
        description = "How far below the maximum scaling frequency the cores are actually running. A floor that rises under load is thermal or power throttling.";
        unit = "percentunit";
        targets = [
          (target {
            expr = "avg_over_time(avg1m:cpu_throttled_ratio[$smooth])";
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Filesystem free";
        unit = "percentunit";
        max = 1;
        min = 0;
        targets = [
          (target {
            expr = "min_over_time(min1m:fs_free_ratio[$smooth])";
            legend = "{{instance}} {{mountpoint}}";
          })
        ];
      })
      (stat {
        title = "Days until full";
        description = "Linear extrapolation of the last week of free space. Negative or absent means no measurable downward trend.";
        unit = "d";
        decimals = 1;
        targets = [
          (target {
            expr = "predict_linear(min1m:fs_avail_bytes[7d], 0) / -deriv(min1m:fs_avail_bytes[7d]) / 86400";
            legend = "{{instance}} {{mountpoint}}";
            instant = true;
          })
        ];
      })
      (ts {
        title = "Failed systemd units";
        decimals = 0;
        targets = [
          (target {
            expr = "max_over_time(max1m:systemd_failed_units[$smooth])";
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Prometheus tier health";
        description = "Head series in each tier. A hi-res tier that stops growing, or scrape durations approaching the interval, means the one-second scrape is no longer keeping up.";
        targets = [
          (target {
            expr = "prometheus_tsdb_head_series";
            legend = "{{instance}} series";
          })
          (target {
            expr = "rate(prometheus_tsdb_head_samples_appended_total[5m])";
            legend = "{{instance}} samples/s";
          })
        ];
      })
      (ts {
        title = "Scrape duration";
        unit = "s";
        targets = [
          (target {
            expr = "scrape_duration_seconds";
            legend = "{{instance}} {{job}}";
          })
        ];
      })
    ];
  };

  # Archive folder: hourly aggregates, kept indefinitely.

  archiveEnergy = dashboard {
    uid = "archive-energy";
    title = "Energy";
    datasource = "prometheus-archive";
    from = "now-1y";
    refresh = "15m";
    tags = [ "archive" ];
    panels = [
      (stat {
        title = "Energy over range";
        w = 8;
        h = 5;
        unit = "kwatth";
        decimals = 1;
        targets = [
          (target {
            expr = "sum_over_time(avg1h:pc_power_watts[$__range]) / 1000";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (stat {
        title = "Cost over range";
        w = 8;
        h = 5;
        unit = "currencyGBP";
        decimals = 2;
        targets = [
          (target {
            expr = "sum_over_time(avg1h:pc_power_watts[$__range]) / 1000 * on(instance) group_left() max1h:tariff_gbp_per_kwh";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (stat {
        title = "Mean draw";
        w = 8;
        h = 5;
        unit = "watt";
        decimals = 0;
        targets = [
          (target {
            expr = "avg_over_time(avg1h:pc_power_watts[$__range])";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (bar {
        title = "Energy per day";
        description = "Each hourly point is a mean wattage covering exactly one hour, so summing a day's points gives watt-hours directly. Bars align to calendar days.";
        w = 24;
        h = 9;
        unit = "kwatth";
        decimals = 2;
        targets = [
          (target {
            expr = "sum_over_time(avg1h:pc_power_watts[1d]) / 1000";
            legend = "{{instance}}";
            interval = "1d";
          })
        ];
      })
      (bar {
        title = "Cost per day";
        w = 24;
        h = 9;
        unit = "currencyGBP";
        decimals = 2;
        targets = [
          (target {
            expr = "sum_over_time(avg1h:pc_power_watts[1d]) / 1000 * on(instance) group_left() max1h:tariff_gbp_per_kwh";
            legend = "{{instance}}";
            interval = "1d";
          })
        ];
      })
      (bar {
        title = "Energy per month";
        w = 12;
        h = 8;
        unit = "kwatth";
        decimals = 1;
        targets = [
          (target {
            expr = "sum_over_time(avg1h:pc_power_watts[30d]) / 1000";
            legend = "{{instance}}";
            interval = "30d";
          })
        ];
      })
      (ts {
        title = "Daily mean and peak draw";
        w = 12;
        h = 8;
        unit = "watt";
        overrides = [ (dimmed ".*peak$") ];
        targets = [
          (target {
            expr = "avg_over_time(avg1h:pc_power_watts[1d])";
            legend = "{{instance}}";
            interval = "1d";
          })
          (target {
            expr = "max_over_time(max1h:pc_power_watts[1d])";
            legend = "{{instance}} peak";
            interval = "1d";
          })
        ];
      })
    ];
  };

  archiveUptime = dashboard {
    uid = "archive-uptime";
    title = "Uptime";
    datasource = "prometheus-archive";
    from = "now-1y";
    refresh = "15m";
    tags = [ "archive" ];
    panels = [
      (stat {
        title = "Availability over range";
        w = 12;
        h = 5;
        unit = "percentunit";
        decimals = 4;
        targets = [
          (target {
            expr = "avg_over_time(avg1h:up[$__range])";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (stat {
        title = "Downtime over range";
        w = 12;
        h = 5;
        unit = "s";
        decimals = 0;
        targets = [
          (target {
            expr = "(1 - avg_over_time(avg1h:up[$__range])) * $__range_s";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (bar {
        title = "Uptime per day";
        description = "Same geometry as the energy-per-day bars, so the two line up when read side by side.";
        w = 24;
        h = 9;
        unit = "percentunit";
        max = 1;
        min = 0;
        decimals = 3;
        targets = [
          (target {
            expr = "avg_over_time(avg1h:up[1d])";
            legend = "{{instance}}";
            interval = "1d";
          })
        ];
      })
      (bar {
        title = "Uptime per month";
        w = 12;
        h = 8;
        unit = "percentunit";
        max = 1;
        min = 0;
        decimals = 4;
        targets = [
          (target {
            expr = "avg_over_time(avg1h:up[30d])";
            legend = "{{instance}}";
            interval = "30d";
          })
        ];
      })
      (timeline {
        title = "Reachability";
        w = 12;
        h = 8;
        mappings = upMappings;
        targets = [
          (target {
            expr = "avg1h:up";
            legend = "{{instance}}";
          })
        ];
      })
    ];
  };

  archiveCapacity = dashboard {
    uid = "archive-capacity";
    title = "Capacity";
    datasource = "prometheus-archive";
    from = "now-1y";
    refresh = "15m";
    tags = [ "archive" ];
    panels = [
      (stat {
        title = "RAM installed";
        w = 8;
        h = 5;
        unit = "bytes";
        decimals = 0;
        targets = [
          (target {
            expr = "max1h:mem_total_bytes";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (stat {
        title = "CPU cores";
        w = 8;
        h = 5;
        decimals = 0;
        targets = [
          (target {
            expr = "max1h:cpu_cores";
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (stat {
        title = "Disk installed";
        w = 8;
        h = 5;
        unit = "bytes";
        decimals = 0;
        targets = [
          (target {
            expr = ''sum by (instance) (max1h:fs_size_bytes{mountpoint="/"})'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (ts {
        title = "Memory used against installed";
        description = "Daily mean and peak against capacity. Over a year this is what tells you whether the machine is growing into its RAM.";
        w = 24;
        h = 10;
        unit = "bytes";
        min = 0;
        overrides = [ (dimmed ".*(capacity|peak)$") ];
        targets = [
          (target {
            expr = "avg_over_time(avg1h:mem_used_bytes[1d])";
            legend = "{{instance}} used";
            interval = "1d";
          })
          (target {
            expr = "max_over_time(max1h:mem_used_bytes[1d])";
            legend = "{{instance}} peak";
            interval = "1d";
          })
          (target {
            expr = "max_over_time(max1h:mem_total_bytes[1d])";
            legend = "{{instance}} capacity";
            interval = "1d";
          })
        ];
      })
      (bar {
        title = "Peak memory use per day";
        w = 24;
        h = 9;
        unit = "percentunit";
        max = 1;
        min = 0;
        decimals = 2;
        targets = [
          (target {
            expr = "max_over_time(max1h:mem_used_ratio[1d])";
            legend = "{{instance}}";
            interval = "1d";
          })
        ];
      })
      (ts {
        title = "Filesystem free against size";
        w = 24;
        h = 9;
        unit = "bytes";
        min = 0;
        overrides = [ (dimmed ".*size$") ];
        targets = [
          (target {
            expr = "min_over_time(min1h:fs_avail_bytes[1d])";
            legend = "{{instance}} {{mountpoint}} free";
            interval = "1d";
          })
          (target {
            expr = "max_over_time(max1h:fs_size_bytes[1d])";
            legend = "{{instance}} {{mountpoint}} size";
            interval = "1d";
          })
        ];
      })
    ];
  };

  archiveThermal = dashboard {
    uid = "archive-thermal";
    title = "Thermal history";
    datasource = "prometheus-archive";
    from = "now-1y";
    refresh = "15m";
    tags = [ "archive" ];
    panels = [
      (ts {
        title = "Daily temperature envelope";
        description = "Daily minimum, mean and maximum per sensor. Over a year this separates seasonal ambient drift from cooling that is genuinely degrading.";
        w = 24;
        h = 10;
        unit = "celsius";
        overrides = [ (dimmed ".*(peak|floor)$") ];
        targets = [
          (target {
            expr = "avg_over_time(avg1h:temp_celsius[1d])";
            legend = "{{instance}} {{name}}";
            interval = "1d";
          })
          (target {
            expr = "max_over_time(max1h:temp_celsius[1d])";
            legend = "{{instance}} {{name}} peak";
            interval = "1d";
          })
          (target {
            expr = "min_over_time(min1h:temp_celsius[1d])";
            legend = "{{instance}} {{name}} floor";
            interval = "1d";
          })
        ];
      })
      (bar {
        title = "Peak temperature per day";
        w = 24;
        h = 9;
        unit = "celsius";
        decimals = 0;
        targets = [
          (target {
            expr = "max_over_time(max1h:temp_celsius[1d])";
            legend = "{{instance}} {{name}}";
            interval = "1d";
          })
        ];
      })
      (ts {
        title = "Daily mean fan speed";
        w = 12;
        h = 8;
        unit = "rotrpm";
        targets = [
          (target {
            expr = "avg_over_time(avg1h:fan_rpm[1d])";
            legend = "{{instance}} {{name}}";
            interval = "1d";
          })
        ];
      })
      (ts {
        title = "Fan speed per degree above ambient";
        description = "Rising over months means the fans are working harder for the same temperature, which is what dust buildup looks like.";
        w = 12;
        h = 8;
        targets = [
          (target {
            expr = "max by (instance) (avg_over_time(avg1h:fan_rpm[1d])) / max by (instance) (avg_over_time(avg1h:temp_celsius[1d]))";
            legend = "{{instance}}";
            interval = "1d";
          })
        ];
      })
    ];
  };
in

{
  live = {
    "power.json" = livePower;
    "system.json" = liveSystem;
  };

  history = {
    "power.json" = historyPower;
    "network.json" = historyNetwork;
    "fleet.json" = historyFleet;
    "system.json" = historySystem;
  };

  archive = {
    "energy.json" = archiveEnergy;
    "uptime.json" = archiveUptime;
    "thermal.json" = archiveThermal;
    "capacity.json" = archiveCapacity;
  };
}

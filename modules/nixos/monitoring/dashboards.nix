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
      maxDataPoints ? null,
      refId ? null,
      datasource ? null,
    }:
    {
      inherit expr instant;
      legendFormat = legend;
      editorMode = "code";
      range = !instant;
      format = format;
    }
    // lib.optionalAttrs (interval != null) { inherit interval; }
    // lib.optionalAttrs (interval == null && !instant && lib.hasInfix "[$smooth]" expr) {
      interval = "$smooth";
    }
    // lib.optionalAttrs (maxDataPoints != null) { inherit maxDataPoints; }
    // lib.optionalAttrs (refId != null) { inherit refId; }
    // lib.optionalAttrs (datasource != null) { inherit datasource; };

  withRefIds = lib.imap0 (
    i: t: if t ? refId then t else t // { refId = lib.elemAt lib.strings.upperChars i; }
  );

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
      links ? [ ],
      repeat ? null,
      repeatDirection ? null,
      maxPerRow ? null,
      datasource ? null,
      color ? null,
    }:
    {
      inherit
        type
        title
        w
        h
        options
        transformations
        links
        ;
      targets = withRefIds targets;
      fieldConfig = {
        defaults = {
          inherit unit mappings;
          custom = custom;
        }
        // lib.optionalAttrs (max != null) { inherit max; }
        // lib.optionalAttrs (min != null) { inherit min; }
        // lib.optionalAttrs (color != null) { inherit color; }
        // lib.optionalAttrs (decimals != null) { inherit decimals; };
        inherit overrides;
      };
    }
    // lib.optionalAttrs (repeat != null) { inherit repeat; }
    // lib.optionalAttrs (repeatDirection != null) { inherit repeatDirection; }
    // lib.optionalAttrs (maxPerRow != null) { inherit maxPerRow; }
    // lib.optionalAttrs (datasource != null) { inherit datasource; }
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

  gradientSeriesFor = args:
    let
      instancePrefix = "{{instance}}";
      suffixFor = seriesTarget:
        let
          legend = seriesTarget.legendFormat or "";
          suffix = lib.removePrefix "${instancePrefix} " legend;
        in
        if legend == instancePrefix then
          ""
        else if lib.hasPrefix "${instancePrefix} " legend && !lib.hasInfix "{{" suffix then
          suffix
        else
          null;
      inferred = map suffixFor (args.targets or [ ]);
    in
    if args ? gradientSeries then
      args.gradientSeries
    else if builtins.all (suffix: suffix != null) inferred then
      inferred
    else
      [ ];

  ts =
    args:
    let
      panelArgs = builtins.removeAttrs args [ "gradientSeries" ];
    in
    panel "timeseries" (
      {
        custom = lineCustom;
        options = legendOptions;
      }
      // panelArgs
      // {
        overrides = hostGradientOverrides (gradientSeriesFor args) ++ (args.overrides or [ ]);
      }
    );

  boundedAverage = upMetric: expression:
    ''avg_over_time((${expression})[$smooth:]) ''
    + ''and (${expression}) ''
    + ''and (count_over_time((${expression})[1m:] offset $smooth) > 0) ''
    + ''and on(instance) (min_over_time(${upMetric}{instance=~"$host"}[$smooth:]) == 1)'';

  smoothLiveTarget = seriesTarget:
    if lib.hasInfix "$smooth" seriesTarget.expr then
      seriesTarget
    else
      seriesTarget // { expr = boundedAverage "host:up" seriesTarget.expr; };

  livePanels = map (
    panel:
    if lib.elem panel.type [ "timeseries" "status-history" ] then
      panel // { targets = map smoothLiveTarget panel.targets; }
    else
      panel
  );

  stat = args: panel "stat" ({ options = statOptions; } // args);
  barGauge =
    args:
    panel "bargauge" (
      {
        options = {
          displayMode = "gradient";
          orientation = "horizontal";
          reduceOptions = {
            calcs = [ "lastNotNull" ];
            fields = "";
            values = false;
          };
          showUnfilled = true;
          valueMode = "color";
        };
      }
      // args
    );
  bar =
    args:
    let
      panelArgs = builtins.removeAttrs args [ "gradientSeries" ];
    in
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
      // panelArgs
      // {
        overrides = hostGradientOverrides (gradientSeriesFor args) ++ (args.overrides or [ ]);
      }
    );
  pie =
    args:
    let
      panelArgs = builtins.removeAttrs args [ "gradientSeries" ];
    in
    panel "piechart" (
      {
        options = {
          displayLabels = [ "value" ];
          legend = {
            displayMode = "table";
            placement = "right";
            showLegend = true;
            values = [ "value" ];
          };
          pieType = "pie";
          reduceOptions = {
            calcs = [ "lastNotNull" ];
            fields = "";
            values = false;
          };
          tooltip.mode = "single";
        };
      }
      // panelArgs
      // {
        overrides = hostGradientOverrides (gradientSeriesFor args) ++ (args.overrides or [ ]);
      }
    );
  table = args: panel "table" args;
  nodeGraph = args: panel "nodeGraph" args;
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
  xy =
    args:
    let
      panelArgs = builtins.removeAttrs args [ "gradientSeries" ];
    in
    panel "xychart" (
      panelArgs
      // {
        overrides = hostGradientOverrides (gradientSeriesFor args) ++ (args.overrides or [ ]);
      }
    );

  status =
    args:
    panel "status-history" (
      {
        options = {
          showValue = "never";
          rowHeight = 0.8;
          colWidth = 0.9;
          legend = {
            displayMode = "hidden";
            placement = "bottom";
          };
          tooltip.mode = "multi";
        };
        custom = {
          fillOpacity = 90;
          lineWidth = 0;
        };
      }
      // args
    );

  alertList = args: panel "alertlist" args;
  logs =
    args:
    panel "logs" (
      {
        options = {
          showTime = true;
          showLabels = false;
          showCommonLabels = false;
          wrapLogMessage = true;
          prettifyLogMessage = false;
          enableLogDetails = true;
          dedupStrategy = "none";
          sortOrder = "Descending";
        };
      }
      // args
    );

  alertHostFilter = hostFilter:
    ''| json | label_format alertHost="{{ or .labels_instance .labels_host | replace \"_\" \"\" }}" | alertHost=~"(${hostFilter})|"'';

  recentAlerts = {
    hostFilter,
    severityFilter ? ".*",
    ruleFilter ? ".*",
    stateFilter ? ".*",
  }:
    logs {
      title = "Recent alerts";
      description = "Latest alert state changes.";
      w = 24;
      h = 10;
      datasource = {
        type = "loki";
        uid = "loki";
      };
      targets = [
        (target {
          expr = ''{from="state-history"} ${alertHostFilter hostFilter} | labels_severity=~"${severityFilter}" | ruleTitle=~"${ruleFilter}" | current=~"${stateFilter}" | line_format "{{.ruleTitle}}  {{.alertHost}}  {{.labels_severity}}  {{.previous}} → {{.current}}"'';
          maxDataPoints = 30;
        })
      ];
    };

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

  rightAxisUnit = pattern: unit: {
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
        value = unit;
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

  fixedColor = pattern: color: {
    matcher = {
      id = "byRegexp";
      options = pattern;
    };
    properties = [
      {
        id = "color";
        value = {
          mode = "fixed";
          fixedColor = color;
        };
      }
    ];
  };

  hostColorScales = {
    desktopnew = [
      [ 24 70 128 ]
      [ 8 81 156 ]
      [ 33 113 181 ]
      [ 66 146 198 ]
      [ 107 174 214 ]
      [ 158 202 225 ]
      [ 198 219 239 ]
    ];
    desktopold = [
      [ 84 35 145 ]
      [ 84 39 143 ]
      [ 106 81 163 ]
      [ 128 125 186 ]
      [ 158 154 200 ]
      [ 188 189 220 ]
      [ 218 218 235 ]
    ];
    laptop = [
      [ 150 58 16 ]
      [ 166 54 3 ]
      [ 217 72 1 ]
      [ 241 105 19 ]
      [ 253 141 60 ]
      [ 253 174 107 ]
      [ 253 208 162 ]
    ];
    pi = [
      [ 18 92 43 ]
      [ 0 109 44 ]
      [ 35 139 69 ]
      [ 65 171 93 ]
      [ 116 196 118 ]
      [ 161 217 155 ]
      [ 199 233 192 ]
    ];
  };

  hexDigits = lib.stringToCharacters "0123456789ABCDEF";

  remainder = numerator: denominator:
    numerator - builtins.div numerator denominator * denominator;

  byteToHex = value:
    "${lib.elemAt hexDigits (builtins.div value 16)}${lib.elemAt hexDigits (remainder value 16)}";

  rgbToHex = rgb: "#${lib.concatMapStrings byteToHex rgb}";

  roundedDivide = numerator: denominator:
    if numerator < 0 then
      0 - builtins.div (0 - numerator + builtins.div denominator 2) denominator
    else
      builtins.div (numerator + builtins.div denominator 2) denominator;

  interpolatedColor = scale: count: index:
    let
      lastScaleIndex = builtins.length scale - 1;
      denominator = count - 1;
      position = index * lastScaleIndex;
      leftIndex = builtins.div position denominator;
      rightIndex = lib.min (leftIndex + 1) lastScaleIndex;
      fraction = remainder position denominator;
      left = lib.elemAt scale leftIndex;
      right = lib.elemAt scale rightIndex;
      rgb = lib.imap0 (
        channel: value:
        value + roundedDivide ((lib.elemAt right channel - value) * fraction) denominator
      ) left;
    in
    rgbToHex rgb;

  middleColor = scale: rgbToHex (lib.elemAt scale (builtins.div (builtins.length scale - 1) 2));

  hostGradientOverrides = seriesSuffixes:
    let
      count = builtins.length seriesSuffixes;
      baseOverrides = lib.mapAttrsToList (
        host: scale: fixedColor "^${host}( .*)?$" (middleColor scale)
      ) hostColorScales;
      seriesOverrides = lib.concatLists (
        lib.imap0 (
          index: suffix:
          lib.mapAttrsToList (
            host: scale:
            fixedColor "^${host}${lib.optionalString (suffix != "") " ${suffix}"}$" (
              if count <= 1 then middleColor scale else interpolatedColor scale count index
            )
          ) hostColorScales
        ) seriesSuffixes
      );
    in
    baseOverrides ++ seriesOverrides;

  upMappings = [
    {
      type = "value";
      options = {
        "0".text = "Down";
        "1".text = "Up";
      };
    }
  ];

  upColor = {
    mode = "continuous-RdYlGr";
  };

  upSelector = ''{instance=~"$host",instance!~"127[.]0[.]0[.]1(:[0-9]+)?"}'';

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

  liveRangeSeconds = 3600;
  liveDivisor = 300;
  historyDivisor = 30;

  smoothBuckets = [
    { s = 1; t = "1s"; }
    { s = 2; t = "2s"; }
    { s = 5; t = "5s"; }
    { s = 10; t = "10s"; }
    { s = 15; t = "15s"; }
    { s = 20; t = "20s"; }
    { s = 30; t = "30s"; }
    { s = 45; t = "45s"; }
    { s = 60; t = "1m"; }
    { s = 120; t = "2m"; }
    { s = 300; t = "5m"; }
    { s = 600; t = "10m"; }
    { s = 900; t = "15m"; }
    { s = 1200; t = "20m"; }
    { s = 1800; t = "30m"; }
    { s = 2700; t = "45m"; }
    { s = 3600; t = "1h"; }
    { s = 5400; t = "90m"; }
    { s = 7200; t = "2h"; }
    { s = 10800; t = "3h"; }
    { s = 21600; t = "6h"; }
    { s = 43200; t = "12h"; }
    { s = 86400; t = "1d"; }
    { s = 172800; t = "2d"; }
    { s = 302400; t = "84h"; }
    { s = 604800; t = "7d"; }
    { s = 1209600; t = "14d"; }
    { s = 2592000; t = "30d"; }
    { s = 15552000; t = "180d"; }
    { s = 31536000; t = "1y"; }
  ];

  rawSmoothSeconds =
    ''(''${__range_s} <= bool ${toString liveRangeSeconds}) * ''${__range_s} / ${toString liveDivisor}''
    + '' + (''${__range_s} > bool ${toString liveRangeSeconds}) * ''${__range_s} / ${toString historyDivisor}'';

  labelled = b: ''label_replace(vector(${toString b.s}), "w", "${b.t}", "", "")'';

  smoothSeconds =
    "topk(1, "
    + lib.concatStringsSep " or " (
      map (b: "(${labelled b} and on() (vector(${rawSmoothSeconds}) >= ${toString b.s}))") (
        lib.reverseList smoothBuckets
      )
      ++ [ (labelled (lib.head smoothBuckets)) ]
    )
    + ")";

  defaultSmooth = "2s";

  smoothVariable = {
    name = "smooth";
    label = "Smoothing";
    type = "custom";
    query = lib.concatMapStringsSep "," (b: b.t) smoothBuckets;
    allowCustomValue = true;
    current = {
      text = defaultSmooth;
      value = defaultSmooth;
      selected = true;
    };
    options = map (b: {
      text = b.t;
      value = b.t;
      selected = b.t == defaultSmooth;
    }) smoothBuckets;
  };

  smoothFor =
    rangeSeconds:
    let
      raw =
        if rangeSeconds <= liveRangeSeconds then
          rangeSeconds / liveDivisor
        else
          rangeSeconds / historyDivisor;
      fits = lib.filter (b: b.s <= raw) smoothBuckets;
    in
    if fits == [ ] then (lib.head smoothBuckets).t else (lib.last fits).t;

  smoothBanner = {
    type = "text";
    title = "";
    w = 24;
    h = 2;
    transparent = true;
    options = {
      mode = "markdown";
      content = "Smoothing window: **$smooth** (every series here is averaged over it).";
    };
  };

  tariffVariable = textboxVariable "tariff" "Electricity (p/kWh)" "20.88";

  resolutionVariable = {
    name = "res";
    label = "Resolution";
    type = "datasource";
    query = "prometheus";
    refresh = 1;
    current = {
      text = "Prometheus";
      value = "prometheus";
      selected = true;
    };
    options = [ ];
  };

  hostVariable =
    datasource:
    let
      metric =
        if datasource == "prometheus" then
          "host:up"
        else if datasource == "prometheus-lt" then
          "host:up"
        else
          "host:up";
      # Historical series created before host relabelling must not surface as
      # selectable hosts in Grafana.
      hostSelector = ''{instance!~"127[.]0[.]0[.]1(:[0-9]+)?"}'';
    in
    {
      name = "host";
      label = "Host";
      type = "query";
      datasource = {
        type = "prometheus";
        uid = datasource;
      };
      query = {
        query = "label_values(${metric}${hostSelector}, instance)";
        refId = "StandardVariableQuery";
      };
      definition = "label_values(${metric}${hostSelector}, instance)";
      refresh = 1;
      sort = 1;
      multi = true;
      includeAll = true;
      allValue = ".*";
      current = {
        text = "All";
        value = "$__all";
        selected = true;
      };
      options = [ ];
    };

  sensorVariable =
    datasource:
    let
      metric =
        if datasource == "prometheus" then
          "sensor:temp_celsius"
        else if datasource == "prometheus-lt" then
          "sensor:temp_celsius"
        else
          "sensor:temp_celsius";
    in
    {
      name = "sensor";
      label = "Sensors";
      type = "query";
      datasource = {
        type = "prometheus";
        uid = datasource;
      };
      query = {
        query = ''label_values(${metric}{instance=~"$host"}, name)'';
        refId = "StandardVariableQuery";
      };
      definition = ''label_values(${metric}{instance=~"$host"}, name)'';
      refresh = 1;
      sort = 1;
      multi = true;
      includeAll = true;
      allValue = ".*";
      current = {
        text = "CPU Tctl";
        value = [ "CPU Tctl" ];
        selected = true;
      };
      options = [ ];
    };

  capacityVariable =
    datasource:
    let
      metric =
        if datasource == "prometheus-archive" then "(mem:capacity_info_max or mem:capacity_info)" else "(mem:capacity_info_max or mem:capacity_info)";
    in
    {
      name = "capacity";
      label = "RAM capacity";
      type = "query";
      datasource = {
        type = "prometheus";
        uid = datasource;
      };
      query = {
        query = "label_values(${metric}, capacity)";
        refId = "StandardVariableQuery";
      };
      definition = "label_values(${metric}, capacity)";
      refresh = 1;
      sort = 3;
      multi = true;
      includeAll = true;
      allValue = ".*";
      current = {
        text = "All";
        value = "$__all";
        selected = true;
      };
      options = [ ];
    };

  fleetHostVariable =
    datasource:
    (hostVariable datasource)
    // {
      current = {
        text = "All";
        value = "$__all";
        selected = true;
      };
    };

  dashboardLink = title: uid: {
    inherit title;
    type = "link";
    url = "/d/${uid}";
    includeVars = true;
    keepTime = true;
    targetBlank = false;
  };

  presetLink = title: uid: from: refresh: {
    inherit title;
    type = "link";
    url = "/d/${uid}?from=${from}&to=now&refresh=${refresh}";
    includeVars = false;
    keepTime = false;
    targetBlank = false;
  };

  textboxVariable = name: label: value: {
    inherit name label;
    type = "textbox";
    query = value;
    current = {
      text = value;
      inherit value;
      selected = true;
    };
    options = [ ];
  };

  logHostVariable = {
    name = "host";
    label = "Host";
    type = "query";
    datasource = {
      type = "loki";
      uid = "loki";
    };
    query = ''label_values({source="journal"}, host)'';
    definition = ''label_values({source="journal"}, host)'';
    refresh = 1;
    multi = true;
    includeAll = true;
    allValue = ".*";
    current = {
      text = "All";
      value = "$__all";
      selected = true;
    };
    options = [ ];
  };

  majorTemperatureTargets = [
    (target {
      expr = ''max by (instance) (temp:major_celsius{instance=~"$host"})'';
      legend = "{{instance}} hottest";
    })
    (target {
      expr = ''temp:major_celsius{instance=~"$host",component="CPU"}'';
      legend = "{{instance}} CPU";
    })
    (target {
      expr = ''temp:major_celsius{instance=~"$host",component="Box"}'';
      legend = "{{instance}} case";
    })
  ];

  overviewMajorTemperatureTargets = [
    (target {
      expr = ''max by (instance) (${boundedAverage "host:up" ''temp:major_celsius{instance=~"$host"}''})'';
      legend = "{{instance}} hottest";
    })
    (target {
      expr = boundedAverage "host:up" ''temp:major_celsius{instance=~"$host",component="CPU"}'';
      legend = "{{instance}} CPU";
    })
    (target {
      expr = boundedAverage "host:up" ''temp:major_celsius{instance=~"$host",component="Box"}'';
      legend = "{{instance}} case";
    })
  ];

  smoothedMajorTemperatureTargets = [
    (target {
      expr = ''max by (instance) (avg_over_time(temp:major_celsius{instance=~"$host"}[$smooth]))'';
      legend = "{{instance}} hottest";
    })
    (target {
      expr = ''avg_over_time(temp:major_celsius{instance=~"$host",component="CPU"}[$smooth])'';
      legend = "{{instance}} CPU";
    })
    (target {
      expr = ''avg_over_time(temp:major_celsius{instance=~"$host",component="Box"}[$smooth])'';
      legend = "{{instance}} case";
    })
  ];

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
      links ? [ ],
    }:
    let
      ds = {
        type =
          if datasource == "loki" then
            "loki"
          else if datasource == "tempo" then
            "tempo"
          else
            "prometheus";
        uid = datasource;
      };
      attach =
        p:
        let
          panelDatasource = p.datasource or ds;
        in
        p
        // {
          datasource = panelDatasource;
          targets = map (t: t // { datasource = t.datasource or panelDatasource; }) (p.targets or [ ]);
        };
    in
    {
      inherit
        uid
        title
        refresh
        tags
        links
        ;
      schemaVersion = 39;
      timezone = "browser";
      editable = false;
      time = {
        inherit from;
        to = "now";
      };
      templating.list = variables;
      panels = lib.imap1 (i: p: attach (p // { id = i; })) (
        layout (lib.optional (lib.any (v: v.name == "smooth") variables) smoothBanner ++ panels)
      );
    };

  overview = dashboard {
    uid = "overview";
    title = "Overview";
    datasource = "prometheus";
    from = "now-15m";
    refresh = "5s";
    tags = [ "home" ];
    variables = [
      (fleetHostVariable "prometheus")
      smoothVariable
      tariffVariable
    ];
    links = [
      (dashboardLink "Alerts and triage" "alerts")
      (dashboardLink "System" "system")
      (dashboardLink "Power and thermals" "power")
      (dashboardLink "Fleet" "fleet")
      (dashboardLink "Network" "network")
      (dashboardLink "Nix builds" "nix-builds")
      (dashboardLink "Logs" "logs")
      (dashboardLink "Energy history" "archive-energy")
      (dashboardLink "Tailscale uptime history" "archive-uptime")
    ];
    panels = livePanels [
      (stat {
        title = "Hosts up";
        w = 8;
        h = 5;
        options = statOptions // {
          textMode = "value";
          wideLayout = true;
        };
        mappings = [
          {
            type = "value";
            options = {
              "1" = { text = "0 / 1"; color = "red"; };
              "11" = { text = "1 / 1"; color = "green"; };
              "2" = { text = "0 / 2"; color = "red"; };
              "12" = { text = "1 / 2"; color = "red"; };
              "22" = { text = "2 / 2"; color = "green"; };
              "3" = { text = "0 / 3"; color = "red"; };
              "13" = { text = "1 / 3"; color = "red"; };
              "23" = { text = "2 / 3"; color = "yellow"; };
              "33" = { text = "3 / 3"; color = "green"; };
            };
          }
        ];
        targets = [
          (target {
            expr = ''count(host:up{instance=~"$host"} == 1) * 10 + count(host:up{instance=~"$host"})'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Load pressure";
        w = 5;
        h = 5;
        decimals = 2;
        description = "Load average is the one-minute average number of runnable tasks plus tasks waiting in uninterruptible I/O. This divides it by each host's logical CPU count: 100% means one task per CPU; higher values mean work is queueing.";
        unit = "percentunit";
        targets = [
          (target {
            expr = ''load:pressure_ratio{instance=~"$host"}'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (stat {
        title = "CPU utilisation";
        w = 5;
        h = 5;
        unit = "percentunit";
        min = 0;
        max = 1;
        targets = [
          (target {
            expr = ''cpu:utilisation{instance=~"$host"}'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (stat {
        title = "Memory used";
        w = 5;
        h = 5;
        unit = "percentunit";
        min = 0;
        max = 1;
        targets = [
          (target {
            expr = ''mem:used_ratio{instance=~"$host"}'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (ts {
        title = "Pressure stall";
        description = "The share of time tasks were unable to run because CPU, I/O, or memory was unavailable.";
        w = 24;
        h = 6;
        unit = "percentunit";
        targets = [
          (target {
            expr = ''psi:cpu_waiting{instance=~"$host"}'';
            legend = "{{instance}} CPU";
          })
          (target {
            expr = ''psi:io_stalled{instance=~"$host"}'';
            legend = "{{instance}} I/O";
          })
          (target {
            expr = ''psi:memory_stalled{instance=~"$host"}'';
            legend = "{{instance}} memory";
          })
        ];
      })
      (bar {
        title = "Power draw";
        w = 24;
        h = 8;
        unit = "watt";
        decimals = 0;
        options = {
          xField = "category";
          stacking = "normal";
          showValue = "never";
          xTickLabelRotation = 0;
          legend = {
            displayMode = "list";
            placement = "bottom";
            showLegend = true;
            calcs = [ ];
          };
          tooltip.mode = "multi";
          tooltip.sort = "desc";
        };
        transformations = [
          {
            id = "labelsToFields";
            options = {
              keepLabels = [
                "instance"
                "category"
              ];
              valueLabel = "instance";
            };
          }
          {
            id = "merge";
            options = { };
          }
        ];
        custom = {
          fillOpacity = 80;
          lineWidth = 1;
        };
        targets = [
          (target {
            expr = "label_replace((${boundedAverage "host:up" "pc:power_watts{instance=~\"$host\"}"}), \"category\", \"Current\", \"__name__\", \".*\")";
            instant = true;
          })
          (target {
            datasource = {
              type = "prometheus";
              uid = "prometheus-lt";
            };
            expr = ''label_replace(avg_over_time(pc:power_watts{instance=~"$host"}[24h]), "category", "Mean (24h)", "__name__", ".*")'';
            instant = true;
          })
          (target {
            datasource = {
              type = "prometheus";
              uid = "prometheus-lt";
            };
            expr = ''label_replace(max_over_time((pc:power_watts_max{instance=~"$host"} or pc:power_watts{instance=~"$host"})[24h:]), "category", "Max (24h)", "__name__", ".*")'';
            instant = true;
          })
        ];
      })
      (pie {
        title = "Energy (24h)";
        w = 6;
        h = 5;
        unit = "kwatth";
        decimals = 1;
        targets = [
          (target {
            datasource = {
              type = "prometheus";
              uid = "prometheus-lt";
            };
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[24h]) / 60 / 1000'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (pie {
        title = "Energy (7d)";
        w = 6;
        h = 5;
        unit = "kwatth";
        decimals = 1;
        targets = [
          (target {
            datasource = {
              type = "prometheus";
              uid = "prometheus-lt";
            };
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[7d]) / 60 / 1000'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (pie {
        title = "Cost (24h)";
        w = 6;
        h = 5;
        unit = "currencyGBP";
        decimals = 2;
        targets = [
          (target {
            datasource = {
              type = "prometheus";
              uid = "prometheus-lt";
            };
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[24h]) / 60 / 1000 * ($tariff / 100)'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (pie {
        title = "Cost (7d)";
        w = 6;
        h = 5;
        unit = "currencyGBP";
        decimals = 2;
        targets = [
          (target {
            datasource = {
              type = "prometheus";
              uid = "prometheus-lt";
            };
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[7d]) / 60 / 1000 * ($tariff / 100)'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (stat {
        title = "Total energy (24h)";
        w = 6;
        h = 3;
        unit = "kwatth";
        decimals = 1;
        targets = [
          (target {
            datasource = {
              type = "prometheus";
              uid = "prometheus-lt";
            };
            expr = ''sum(sum_over_time(pc:power_watts{instance=~"$host"}[24h]) / 60 / 1000)'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Total energy (7d)";
        w = 6;
        h = 3;
        unit = "kwatth";
        decimals = 1;
        targets = [
          (target {
            datasource = {
              type = "prometheus";
              uid = "prometheus-lt";
            };
            expr = ''sum(sum_over_time(pc:power_watts{instance=~"$host"}[7d]) / 60 / 1000)'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Total cost (24h)";
        w = 6;
        h = 3;
        unit = "currencyGBP";
        decimals = 2;
        targets = [
          (target {
            datasource = {
              type = "prometheus";
              uid = "prometheus-lt";
            };
            expr = ''sum(sum_over_time(pc:power_watts{instance=~"$host"}[24h]) / 60 / 1000 * ($tariff / 100))'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Total cost (7d)";
        w = 6;
        h = 3;
        unit = "currencyGBP";
        decimals = 2;
        targets = [
          (target {
            datasource = {
              type = "prometheus";
              uid = "prometheus-lt";
            };
            expr = ''sum(sum_over_time(pc:power_watts{instance=~"$host"}[7d]) / 60 / 1000 * ($tariff / 100))'';
            instant = true;
          })
        ];
      })
      (table {
        title = "System session summary";
        description = "Current continuous session, maximum session and observed system uptime over 7 days.";
        w = 24;
        h = 7;
        unit = "dtdurations";
        decimals = 0;
        options = {
          showHeader = true;
          cellHeight = "sm";
          footer.show = false;
        };
        transformations = [
          {
            id = "joinByField";
            options = {
              byField = "instance";
              mode = "outer";
            };
          }
          {
            id = "organize";
            options.renameByName = {
              instance = "Host";
              "Value #A" = "Current continuous";
              "Value #B" = "Maximum session";
              "Value #C" = "Total uptime (7d)";
            };
            options.excludeByName = {
              Time = true;
              __name__ = true;
              job = true;
            };
          }
        ];
        overrides = [
          {
            matcher = {
              id = "byRegexp";
              options = "^(Current continuous|Maximum session)$";
            };
            properties = [
              {
                id = "custom.cellOptions";
                value = {
                  type = "color-background";
                  mode = "gradient";
                };
              }
              {
                id = "color";
                value = {
                  mode = "continuous-RdYlGr";
                };
              }
              {
                id = "min";
                value = 0;
              }
              {
                id = "max";
                value = 172800;
              }
              {
                # A down host has no running session; keep that cell neutral
                # rather than treating zero as the worst uptime.
                id = "mappings";
                value = [
                  {
                    type = "value";
                    options."-1" = {
                      text = "Unknown";
                      color = "#1B1F24";
                    };
                    options."-2" = {
                      text = "S3 (sleep)";
                      color = "#1B1F24";
                    };
                    options."-3" = {
                      text = "S5 (down)";
                      color = "#1B1F24";
                    };
                  }
                ];
              }
            ];
          }
          {
            matcher = {
              id = "byName";
              options = "Total uptime (7d)";
            };
            properties = [
              {
                id = "custom.cellOptions";
                value = {
                  type = "color-background";
                  mode = "gradient";
                };
              }
              {
                id = "color";
                value = {
                  mode = "fixed";
                  fixedColor = "green";
                };
              }
              {
                id = "min";
                value = 0;
              }
              {
                id = "max";
                value = 604800;
              }
            ];
          }
        ];
        targets = [
          (target {
            expr = ''(time() - max by (instance) (host:boot_time_seconds{instance=~"$host"}) and on(instance) (host:up == 1)) or on(instance) (-2 * (host:up == 0) * on(instance) max by (instance) (host_power_state{state="S3"})) or on(instance) (-3 * (host:up == 0) * on(instance) max by (instance) (host_power_state{state="S5"})) or on(instance) ((host:up == 0) * -1)'';
            legend = "{{instance}} current";
            format = "table";
            instant = true;
          })
          (target {
            expr = ''max_over_time((time() - max by (instance) (host:boot_time_seconds{instance=~"$host"}))[$__range:])'';
            legend = "{{instance}} maximum session";
            format = "table";
            instant = true;
          })
          (target {
            datasource = {
              type = "prometheus";
              uid = "prometheus-lt";
            };
            expr = ''max by (instance) (sum_over_time((host:up{instance=~"$host"})[7d:]) * 60 or ((time() - max by (instance) ((host:boot_time_seconds_max{instance=~"$host"} or host:boot_time_seconds{instance=~"$host"}))) and on(instance) (host:up == 1)))'';
            legend = "{{instance}} total uptime (7d)";
            format = "table";
            instant = true;
          })
        ];
      })
      (alertList {
        title = "Active alerts";
        w = 24;
        h = 10;
        links = [ (dashboardLink "Alerts and triage" "alerts") ];
        options = {
          alertName = "";
          dashboardAlerts = false;
          groupBy = [ "severity" ];
          groupMode = "custom";
          maxItems = 20;
          sortOrder = 1;
          stateFilter = {
            alerting = true;
            error = true;
            noData = true;
            normal = false;
            pending = true;
            recovering = true;
          };
          viewMode = "list";
        };
      })
      (ts {
        title = "Load pressure";
        description = "Load average is the one-minute average number of runnable tasks plus tasks waiting in uninterruptible I/O. This divides it by each host's logical CPU count: 100% means one task per CPU; higher values mean work is queueing.";
        w = 24;
        unit = "percentunit";
        targets = [
          (target {
            expr = boundedAverage "host:up" ''load:pressure_ratio{instance=~"$host"}'';
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "CPU utilisation";
        w = 24;
        unit = "percentunit";
        min = 0;
        max = 1;
        targets = [
          (target {
            expr = boundedAverage "host:up" ''cpu:utilisation{instance=~"$host"}'';
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Memory used";
        unit = "percentunit";
        min = 0;
        max = 1;
        targets = [
          (target {
            expr = boundedAverage "host:up" ''mem:used_ratio{instance=~"$host"}'';
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Network received";
        unit = "Bps";
        gradientSeries = [
          "VPN"
          "Tailnet"
          "Direct"
        ];
        targets = [
          (target {
            expr = boundedAverage "host:up" ''net:receive_bytes_by_transport{instance=~"$host"}'';
            legend = "{{instance}} {{transport}}";
          })
        ];
      })
      (ts {
        title = "Network sent";
        unit = "Bps";
        gradientSeries = [
          "VPN"
          "Tailnet"
          "Direct"
        ];
        targets = [
          (target {
            expr = boundedAverage "host:up" ''net:transmit_bytes_by_transport{instance=~"$host"}'';
            legend = "{{instance}} {{transport}}";
          })
        ];
      })
      (ts {
        title = "Major temperatures";
        description = "Shows case, CPU and hottest temperatures.";
        w = 24;
        h = 7;
        unit = "celsius";
        targets = overviewMajorTemperatureTargets;
      })
      (stat {
        title = "Nix rebuilds (24h)";
        w = 6;
        h = 5;
        datasource = {
          type = "loki";
          uid = "loki";
        };
        targets = [
          (target {
            expr = ''sum(count_over_time({service_name="nix-observer-summary"} | json | event="nix_rebuild" [24h]))'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Failed Nix rebuilds (24h)";
        w = 6;
        h = 5;
        datasource = {
          type = "loki";
          uid = "loki";
        };
        targets = [
          (target {
            expr = ''sum(count_over_time({service_name="nix-observer-summary"} | json | event="nix_rebuild" | status="failed" | alert_eligible="true" [24h]))'';
            instant = true;
          })
        ];
      })
      (recentAlerts { hostFilter = "$host"; })
    ];
  };

  alerts = dashboard {
    uid = "alerts";
    title = "Alerts and triage";
    datasource = "prometheus-lt";
    from = "now-7d";
    refresh = "1m";
    tags = [ "alerts" ];
    variables = [
      (fleetHostVariable "prometheus-lt")
      (textboxVariable "severity" "Severity regex" ".*")
      (textboxVariable "rule" "Rule regex" ".*")
      (textboxVariable "state" "State regex" ".*")
    ];
    links = [
      {
        title = "Alert rules";
        type = "link";
        url = "/alerting/list";
        targetBlank = false;
      }
      {
        title = "Native alert history";
        type = "link";
        url = "/alerting/history";
        targetBlank = false;
      }
      (dashboardLink "Overview" "overview")
      (dashboardLink "Fleet" "fleet")
    ];
    panels = [
      (stat {
        title = "Critical firing";
        w = 8;
        h = 5;
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        targets = [
          (target {
            expr = ''count(GRAFANA_ALERTS{alertstate="firing",severity="critical",instance=~"$host"} == 1)'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Warnings firing";
        w = 8;
        h = 5;
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        targets = [
          (target {
            expr = ''count(GRAFANA_ALERTS{alertstate="firing",severity="warning",instance=~"$host"} == 1)'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Pending";
        w = 8;
        h = 5;
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        targets = [
          (target {
            expr = ''count(GRAFANA_ALERTS{alertstate="pending",instance=~"$host"} == 1)'';
            instant = true;
          })
        ];
      })
      (alertList {
        title = "Firing, pending and unhealthy rules";
        w = 24;
        h = 10;
        options = {
          alertName = "";
          dashboardAlerts = false;
          groupBy = [ ];
          groupMode = "default";
          maxItems = 100;
          sortOrder = 1;
          stateFilter = {
            alerting = true;
            error = true;
            noData = true;
            normal = false;
            pending = true;
            recovering = true;
          };
          viewMode = "list";
        };
      })
      (logs {
        title = "Alert history";
        description = "One row per Grafana alert state transition, stored in Loki. Expand a row for the complete rule labels and evaluated values.";
        w = 24;
        h = 14;
        datasource = {
          type = "loki";
          uid = "loki";
        };
        targets = [
          (target {
            expr = ''{from="state-history"} ${alertHostFilter "$host"} | labels_severity=~"$severity" | ruleTitle=~"$rule" | current=~"$state" | line_format "{{.ruleTitle}}  {{.alertHost}}  {{.labels_severity}}  {{.previous}} → {{.current}}  value={{.values}}"'';
          })
        ];
      })
      (ts {
        title = "Alert transitions per hour";
        w = 24;
        h = 8;
        datasource = {
          type = "loki";
          uid = "loki";
        };
        targets = [
          (target {
            expr = ''sum(count_over_time({from="state-history"} ${alertHostFilter "$host"} | labels_severity=~"$severity" | ruleTitle=~"$rule" | current=~"$state" [1h]))'';
            interval = "1h";
            maxDataPoints = 200;
          })
        ];
      })
      (logs {
        title = "Recent failures and unhealthy evaluations";
        w = 12;
        h = 10;
        datasource = {
          type = "loki";
          uid = "loki";
        };
        targets = [
          (target {
            expr = ''{from="state-history"} ${alertHostFilter "$host"} | current=~"Alerting.*|Error.*|NoData.*" | line_format "{{.ruleTitle}}  {{.alertHost}}  {{.previous}} → {{.current}}  {{.values}}"'';
          })
        ];
      })
      (logs {
        title = "Recently resolved";
        w = 12;
        h = 10;
        datasource = {
          type = "loki";
          uid = "loki";
        };
        targets = [
          (target {
            expr = ''{from="state-history"} ${alertHostFilter "$host"} | previous=~"Alerting.*|Error.*|NoData.*" | current=~"Normal.*" | line_format "{{.ruleTitle}}  {{.alertHost}}  {{.previous}} → {{.current}}"'';
          })
        ];
      })
      (timeline {
        title = "Host reachability";
        mappings = upMappings;
        color = upColor;
        min = 0;
        max = 1;
        targets = [
          (target {
            expr = ''max by (instance) (host:up${upSelector})'';
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Thermal context";
        unit = "celsius";
        targets = [
          (target {
            expr = ''max by (instance) (temp:major_celsius{instance=~"$host"})'';
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Filesystem headroom";
        unit = "percentunit";
        min = 0;
        max = 1;
        targets = [
          (target {
            expr = ''(fs:free_ratio_min{instance=~"$host"} or fs:free_ratio{instance=~"$host"})'';
            legend = "{{instance}} {{mountpoint}}";
          })
        ];
      })
      (ts {
        title = "Failed systemd units";
        decimals = 0;
        targets = [
          (target {
            expr = ''(systemd:failed_units_max{instance=~"$host"} or systemd:failed_units{instance=~"$host"})'';
            legend = "{{instance}}";
          })
        ];
      })
      (recentAlerts {
        hostFilter = "$host";
        severityFilter = "$severity";
        ruleFilter = "$rule";
        stateFilter = "$state";
      })
    ];
  };

  livePower = dashboard {
    uid = "power";
    title = "Power and thermals";
    datasource = "prometheus";
    from = "now-15m";
    refresh = "5s";
    tags = [ "live" ];
    variables = [
      (hostVariable "prometheus")
      (sensorVariable "prometheus")
      smoothVariable
    ];
    links = [
      (presetLink "Live" "power" "now-15m" "5s")
      (presetLink "24h" "power" "now-24h" "1m")
      (presetLink "7d" "power" "now-7d" "5m")
      (presetLink "30d" "power" "now-30d" "5m")
      (dashboardLink "System" "system")
      (dashboardLink "Overview" "overview")
    ];
    panels = livePanels [
      (stat {
        title = "Total draw";
        w = 6;
        h = 5;
        unit = "watt";
        decimals = 0;
        targets = [
          (target {
            expr = ''pc:power_watts{instance=~"$host"}'';
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
            expr = ''pc:cpu_power_watts{instance=~"$host"}'';
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
            expr = ''pc:gpu_power_watts{instance=~"$host"}'';
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
            expr = ''temp:major_celsius{instance=~"$host",component="CPU"}'';
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Total device power, broken down";
        description = "Desktop is a modelled wall estimate, laptop uses RAPL platform energy, and Pi uses its configured wall estimate. Hardware-specific measured rails are shown separately.";
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
        overrides = [
          {
            matcher = {
              id = "byRegexp";
              options = ".*total$";
            };
            properties = [
              {
                id = "custom.stacking";
                value = {
                  mode = "none";
                  group = "B";
                };
              }
              {
                id = "custom.fillOpacity";
                value = 0;
              }
              {
                id = "custom.lineWidth";
                value = 3;
              }
            ];
          }
        ];
        targets = [
          (target {
            expr = ''pc:cpu_power_watts{instance=~"$host"}'';
            legend = "{{instance}} CPU";
          })
          (target {
            expr = ''pc:gpu_power_watts{instance=~"$host"}'';
            legend = "{{instance}} GPU";
          })
          (target {
            expr = ''pc:baseline_watts{instance=~"$host"}'';
            legend = "{{instance}} baseline";
          })
          (target {
            expr = ''pc:psu_loss_watts{instance=~"$host"}'';
            legend = "{{instance}} PSU loss";
          })
          (target {
            expr = ''pc:power_watts{instance=~"$host"}'';
            legend = "{{instance}} total";
          })
        ];
      })
      (ts {
        title = "Pi PMIC rail power";
        description = "Measured PMIC output rails; this excludes USB and other direct 5 V loads, so it is not wall power.";
        w = 12;
        h = 8;
        unit = "watt";
        targets = [
          (target {
            expr = ''pi:pmic_rail_watts{instance=~"$host"}'';
            legend = "{{instance}} {{rail}}";
          })
        ];
      })
      (ts {
        title = "Pi supply and firmware health";
        w = 12;
        h = 8;
        unit = "volt";
        targets = [
          (target {
            expr = ''pi_pmic_voltage_volts{instance=~"$host",rail="EXT5V"}'';
            legend = "{{instance}} 5 V supply";
          })
        ];
      })
      (ts {
        title = "Laptop battery power";
        w = 12;
        h = 8;
        unit = "watt";
        targets = [
          (target {
            expr = ''laptop_battery_power_watts{instance=~"$host"}'';
            legend = "{{instance}} {{battery}}";
          })
        ];
      })
      (ts {
        title = "Laptop battery energy";
        w = 12;
        h = 8;
        unit = "watth";
        targets = [
          (target {
            expr = ''laptop_battery_energy_watt_hours{instance=~"$host"}'';
            legend = "{{instance}} {{kind}}";
          })
        ];
      })
      (ts {
        title = "Major temperatures";
        description = "The hottest major sensor, CPU and case/enclosure temperature; use the selectable panel below for individual sensors.";
        unit = "celsius";
        targets = majorTemperatureTargets;
      })
      (ts {
        title = "Selected temperatures";
        description = "Use the Sensors picker above to keep only the entries you want; click a legend entry to isolate it temporarily.";
        unit = "celsius";
        targets = [
          (target {
            expr = ''sensor:temp_celsius{instance=~"$host",name=~"$sensor"}'';
            legend = "{{instance}} {{name}}";
          })
        ];
      })
      (ts {
        title = "Fan speed";
        unit = "rotrpm";
        targets = [
          (target {
            expr = ''fan:rpm{instance=~"$host"} > 0'';
            legend = "{{instance}} {{id}}";
          })
        ];
      })
      (ts {
        title = "Temperature against fan speed";
        description = "Fans on the right axis. Use the Smoothing picker to make the lag between a temperature rise and the fan response easier to inspect.";
        w = 24;
        h = 9;
        unit = "celsius";
        overrides = [ (rightAxis ".*rpm.*") ];
        targets = [
          (target {
            expr = ''temp:major_celsius{instance=~"$host",component="CPU"}'';
            legend = "{{instance}} CPU";
          })
          (target {
            expr = ''fan:rpm{instance=~"$host"} > 0'';
            legend = "{{instance}} {{id}} rpm";
          })
        ];
      })
      (ts {
        title = "CPU frequency";
        unit = "hertz";
        targets = [
          (target {
            expr = ''(cpu:hertz_min{instance=~"$host"} or cpu:hertz{instance=~"$host"})'';
            legend = "{{instance}} min";
          })
          (target {
            expr = ''cpu:hertz{instance=~"$host"}'';
            legend = "{{instance}} mean";
          })
          (target {
            expr = ''(cpu:hertz_max{instance=~"$host"} or cpu:hertz{instance=~"$host"})'';
            legend = "{{instance}} max";
          })
        ];
      })
      (ts {
        title = "Sensor power rails";
        unit = "watt";
        targets = [
          (target {
            expr = ''sensor:power_watt{instance=~"$host"}'';
            legend = "{{instance}} {{name}}";
          })
        ];
      })
      (table {
        title = "Voltage diagnostics";
        unit = "volt";
        targets = [
          (target {
            expr = ''sensor:volts{instance=~"$host"}'';
            legend = "{{instance}} {{name}}";
            format = "table";
            instant = true;
          })
        ];
      })
    ];
  };

  liveSystem = dashboard {
    uid = "system";
    title = "System";
    datasource = "prometheus";
    from = "now-15m";
    refresh = "5s";
    tags = [ "live" ];
    variables = [
      (hostVariable "prometheus")
      (capacityVariable "prometheus")
      smoothVariable
    ];
    links = [
      (presetLink "Live" "system" "now-15m" "5s")
      (presetLink "24h" "system" "now-24h" "1m")
      (presetLink "7d" "system" "now-7d" "5m")
      (presetLink "30d" "system" "now-30d" "5m")
      (dashboardLink "Power and thermals" "power")
      (dashboardLink "Overview" "overview")
    ];
    panels = livePanels [
      (ts {
        title = "CPU core utilisation envelope";
        w = 24;
        unit = "percentunit";
        max = 1;
        min = 0;
        targets = [
          (target {
            expr = ''cpu:core_utilisation_min{instance=~"$host"}'';
            legend = "{{instance}} min";
          })
          (target {
            expr = ''cpu:core_utilisation_avg{instance=~"$host"}'';
            legend = "{{instance}} mean";
          })
          (target {
            expr = ''cpu:core_utilisation_max{instance=~"$host"}'';
            legend = "{{instance}} max";
          })
        ];
      })
      (status {
        title = "CPU core heatmap";
        description = "One row per logical core. Colour shows utilisation over time without trying to draw every core as an overlapping line.";
        w = 24;
        h = 10;
        unit = "percentunit";
        max = 1;
        min = 0;
        targets = [
          (target {
            expr = ''cpu:core_utilisation{instance=~"$host"}'';
            legend = "{{instance}} cpu{{cpu}}";
            interval = "15s";
            maxDataPoints = 120;
          })
        ];
      })
      (table {
        title = "CPU cores now";
        description = "Sorted by utilisation so hot or saturated logical cores rise to the top without drawing every core as a line.";
        w = 24;
        h = 9;
        unit = "percentunit";
        transformations = [
          {
            id = "joinByField";
            options = {
              byField = "cpu";
              mode = "outer";
            };
          }
          {
            id = "organize";
            options.renameByName = {
              instance = "Host";
              cpu = "Core";
              "Value #A" = "Utilisation";
              "Value #B" = "Frequency";
            };
            options.excludeByName = {
              Time = true;
              __name__ = true;
              job = true;
              mode = true;
            };
          }
          {
            id = "sortBy";
            options.sort = [
              {
                field = "Utilisation";
                desc = true;
              }
            ];
          }
        ];
        targets = [
          (target {
            expr = ''cpu:core_utilisation{instance=~"$host"}'';
            format = "table";
            instant = true;
          })
          (target {
            expr = ''node_cpu_scaling_frequency_hertz{instance=~"$host"}'';
            format = "table";
            instant = true;
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
            expr = ''node_memory_MemTotal_bytes{instance=~"$host"}'';
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
            expr = ''mem:used_ratio{instance=~"$host"}'';
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Memory — $capacity machines";
        description = "Used excludes reclaimable cache, so it tracks what the machine actually needs. The dashed line is installed capacity.";
        w = 8;
        h = 8;
        unit = "bytes";
        min = 0;
        repeat = "capacity";
        repeatDirection = "h";
        maxPerRow = 3;
        overrides = [ (dimmed ".*(capacity|cache)$") ];
        targets = [
          (target {
            expr = ''mem:used_bytes{instance=~"$host"} * on(instance) group_left(capacity) (mem:capacity_info_max{capacity=~"$capacity"} or mem:capacity_info{capacity=~"$capacity"})'';
            legend = "{{instance}} used";
          })
          (target {
            expr = ''mem:cached_bytes{instance=~"$host"} * on(instance) group_left(capacity) (mem:capacity_info_max{capacity=~"$capacity"} or mem:capacity_info{capacity=~"$capacity"})'';
            legend = "{{instance}} cache";
          })
          (target {
            expr = ''node_memory_MemTotal_bytes{instance=~"$host"} * on(instance) group_left(capacity) (mem:capacity_info_max{capacity=~"$capacity"} or mem:capacity_info{capacity=~"$capacity"})'';
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
            expr = ''mem:swap_used_bytes{instance=~"$host"}'';
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
            expr = ''psi:cpu_waiting{instance=~"$host"}'';
            legend = "{{instance}} cpu";
          })
          (target {
            expr = ''psi:io_stalled{instance=~"$host"}'';
            legend = "{{instance}} io";
          })
          (target {
            expr = ''psi:memory_stalled{instance=~"$host"}'';
            legend = "{{instance}} memory";
          })
        ];
      })
      (ts {
        title = "Disk throughput";
        unit = "Bps";
        targets = [
          (target {
            expr = ''disk:read_bytes{instance=~"$host"}'';
            legend = "{{instance}} {{device}} read";
          })
          (target {
            expr = ''disk:written_bytes{instance=~"$host"}'';
            legend = "{{instance}} {{device}} write";
          })
        ];
      })
      (ts {
        title = "Disk busy";
        unit = "percentunit";
        targets = [
          (target {
            expr = ''disk:io_time{instance=~"$host"}'';
            legend = "{{instance}} {{device}}";
          })
        ];
      })
      (ts {
        title = "Network received";
        unit = "Bps";
        gradientSeries = [
          "VPN"
          "Tailnet"
          "Direct"
        ];
        targets = [
          (target {
            expr = ''net:receive_bytes_by_transport{instance=~"$host"}'';
            legend = "{{instance}} {{transport}}";
          })
        ];
      })
      (ts {
        title = "Network sent";
        unit = "Bps";
        gradientSeries = [
          "VPN"
          "Tailnet"
          "Direct"
        ];
        targets = [
          (target {
            expr = ''net:transmit_bytes_by_transport{instance=~"$host"}'';
            legend = "{{instance}} {{transport}}";
          })
        ];
      })
      (ts {
        title = "Load pressure";
        description = "Load average is the one-minute average number of runnable tasks plus tasks waiting in uninterruptible I/O. This divides it by each host's logical CPU count: 100% means one task per CPU; higher values mean work is queueing.";
        unit = "percentunit";
        targets = [
          (target {
            expr = ''load:pressure_ratio{instance=~"$host"}'';
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Major temperatures";
        description = "Thermals alongside utilisation make load, throttling and cooling response easy to correlate.";
        w = 24;
        h = 9;
        unit = "celsius";
        targets = majorTemperatureTargets;
      })
    ];
  };

  # History folder: 1-minute aggregates, smoothed by the $smooth variable.

  historyPower = dashboard {
    uid = "power";
    title = "Power and thermals";
    datasource = "prometheus-lt";
    from = "now-7d";
    refresh = "5m";
    tags = [ "history" ];
    variables = [
      (hostVariable "prometheus-lt")
      (sensorVariable "prometheus-lt")
      smoothVariable
      tariffVariable
    ];
    links = [
      (presetLink "Live" "power" "now-15m" "5s")
      (presetLink "24h" "power" "now-24h" "1m")
      (presetLink "7d" "power" "now-7d" "5m")
      (presetLink "30d" "power" "now-30d" "5m")
      (dashboardLink "System" "system")
      (dashboardLink "Thermal archive" "archive-thermal")
    ];
    panels = [
      (barGauge {
        title = "Power draw";
        w = 6;
        h = 7;
        unit = "watt";
        decimals = 0;
        targets = [
          (target {
            expr = ''avg_over_time(pc:power_watts{instance=~"$host"}[$__range])'';
            legend = "{{instance}} mean";
            instant = true;
          })
          (target {
            expr = ''max_over_time((pc:power_watts_max{instance=~"$host"} or pc:power_watts{instance=~"$host"})[$__range:])'';
            legend = "{{instance}} max";
            instant = true;
          })
        ];
      })
      (barGauge {
        title = "Energy";
        w = 6;
        h = 5;
        unit = "kwatth";
        decimals = 1;
        targets = [
          (target {
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[24h]) / 60 / 1000'';
            legend = "{{instance}} 24h";
            instant = true;
          })
          (target {
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[7d]) / 60 / 1000'';
            legend = "{{instance}} 7d";
            instant = true;
          })
        ];
      })
      (barGauge {
        title = "Cost";
        w = 6;
        h = 5;
        unit = "currencyGBP";
        decimals = 2;
        targets = [
          (target {
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[24h]) / 60 / 1000 * ($tariff / 100)'';
            legend = "{{instance}} 24h";
            instant = true;
          })
          (target {
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[7d]) / 60 / 1000 * ($tariff / 100)'';
            legend = "{{instance}} 7d";
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
            expr = ''avg_over_time(pc:power_watts{instance=~"$host"}[$smooth])'';
            legend = "{{instance}}";
          })
          (target {
            expr = ''max_over_time((pc:power_watts_max{instance=~"$host"} or pc:power_watts{instance=~"$host"})[$smooth:])'';
            legend = "{{instance}} peak";
          })
          (target {
            expr = ''min_over_time((pc:power_watts_min{instance=~"$host"} or pc:power_watts{instance=~"$host"})[$smooth:])'';
            legend = "{{instance}} floor";
          })
        ];
      })
      (ts {
        title = "Energy use over time";
        w = 24;
        h = 9;
        unit = "kwatth";
        decimals = 2;
        custom = lineCustom // {
          fillOpacity = 45;
          lineWidth = 1;
          stacking = {
            mode = "normal";
            group = "A";
          };
        };
        targets = [
          (target {
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[$smooth]) / 60 / 1000'';
            legend = "{{instance}}";
            interval = "$smooth";
          })
        ];
      })
      (bar {
        title = "Daily energy and cost";
        description = "Energy is on the left axis; cost is on the right.";
        w = 24;
        h = 8;
        unit = "kwatth";
        decimals = 2;
        overrides = [ (rightAxisUnit "Cost" "currencyGBP") ];
        targets = [
          (target {
            expr = ''sum(sum_over_time(pc:power_watts{instance=~"$host"}[1d])) / 60 / 1000'';
            legend = "Energy";
            interval = "1d";
          })
          (target {
            expr = ''sum(sum_over_time(pc:power_watts{instance=~"$host"}[1d])) / 60 / 1000 * ($tariff / 100)'';
            legend = "Cost";
            interval = "1d";
          })
        ];
      })
      (bar {
        title = "Monthly energy and cost";
        description = "Energy is on the left axis; cost is on the right.";
        w = 24;
        h = 8;
        unit = "kwatth";
        decimals = 2;
        overrides = [ (rightAxisUnit "Cost" "currencyGBP") ];
        targets = [
          (target {
            expr = ''sum(sum_over_time(pc:power_watts{instance=~"$host"}[30d])) / 60 / 1000'';
            legend = "Energy";
            interval = "30d";
          })
          (target {
            expr = ''sum(sum_over_time(pc:power_watts{instance=~"$host"}[30d])) / 60 / 1000 * ($tariff / 100)'';
            legend = "Cost";
            interval = "30d";
          })
        ];
      })
      (ts {
        title = "CPU against GPU power";
        unit = "watt";
        targets = [
          (target {
            expr = ''avg_over_time(pc:cpu_power_watts{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} CPU";
          })
          (target {
            expr = ''avg_over_time(pc:gpu_power_watts{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} GPU";
          })
        ];
      })
      (ts {
        title = "Major thermal history";
        w = 24;
        h = 9;
        unit = "celsius";
        targets = smoothedMajorTemperatureTargets;
      })
      (ts {
        title = "Temperature envelope";
        description = "For one or two selected sensors this acts as a sausage plot: the solid mean sits between the true minimum and maximum for each smoothing window.";
        unit = "celsius";
        overrides = [ (dimmed ".*(peak|floor)$") ];
        targets = [
          (target {
            expr = ''avg_over_time(sensor:temp_celsius{instance=~"$host",name=~"$sensor"}[$smooth])'';
            legend = "{{instance}} {{name}}";
          })
          (target {
            expr = ''max_over_time((sensor:temp_celsius_max{instance=~"$host",name=~"$sensor"} or sensor:temp_celsius{instance=~"$host",name=~"$sensor"})[$smooth:])'';
            legend = "{{instance}} {{name}} peak";
          })
          (target {
            expr = ''min_over_time((sensor:temp_celsius_min{instance=~"$host",name=~"$sensor"} or sensor:temp_celsius{instance=~"$host",name=~"$sensor"})[$smooth:])'';
            legend = "{{instance}} {{name}} floor";
          })
        ];
      })
      (ts {
        title = "Temperature against fan speed";
        w = 24;
        h = 9;
        unit = "celsius";
        overrides = [ (rightAxis ".*rpm.*") ];
        targets = smoothedMajorTemperatureTargets ++ [
          (target {
            expr = ''max by (instance) (avg_over_time(fan:rpm{instance=~"$host"}[$smooth]))'';
            legend = "{{instance}} fan rpm";
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
            expr = ''max by (instance) (avg_over_time(fan:rpm{instance=~"$host"}[$smooth]))'';
            legend = "{{instance}} fan";
          })
          (target {
            expr = ''max by (instance) (avg_over_time(temp:major_celsius{instance=~"$host",component="CPU"}[$smooth]))'';
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
            expr = ''avg_over_time(sensor:temp_celsius{instance=~"$host",name=~"$sensor"}[$smooth])'';
            legend = "{{instance}} {{name}}";
          })
        ];
      })
    ];
  };

  historyNetwork = dashboard {
    uid = "network";
    title = "Network and tailnet";
    datasource = "prometheus-lt";
    from = "now-7d";
    refresh = "5m";
    tags = [ "history" ];
    variables = [
      (hostVariable "prometheus-lt")
      smoothVariable
    ];
    links = [
      (presetLink "Live" "network" "now-15m" "5s")
      (presetLink "24h" "network" "now-24h" "1m")
      (presetLink "7d" "network" "now-7d" "5m")
      (presetLink "30d" "network" "now-30d" "5m")
      (dashboardLink "Fleet" "fleet")
      (dashboardLink "System" "system")
    ];
    panels = [
      (ts {
        title = "Network received";
        w = 12;
        h = 9;
        unit = "Bps";
        gradientSeries = [
          "VPN"
          "Tailnet"
          "Direct"
        ];
        targets = [
          (target {
            expr = ''avg_over_time(net:receive_bytes_by_transport{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} {{transport}}";
          })
        ];
      })
      (ts {
        title = "Network sent";
        w = 12;
        h = 9;
        unit = "Bps";
        gradientSeries = [
          "VPN"
          "Tailnet"
          "Direct"
        ];
        targets = [
          (target {
            expr = ''avg_over_time(net:transmit_bytes_by_transport{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} {{transport}}";
          })
        ];
      })
      (nodeGraph {
        title = "Host-to-host tailnet transfer map";
        description = "Directed edges show the current smoothed send rate. Select hosts above to focus the map; hover an edge for throughput.";
        w = 24;
        h = 14;
        unit = "Bps";
        options = {
          nodes.mainStatUnit = "Bps";
          edges.mainStatUnit = "Bps";
          zoomMode = "cooperative";
        };
        transformations = [
          {
            id = "organize";
            options.renameByName = {
              instance = "source";
              peer = "target";
              Value = "mainstat";
              relay = "detail__relay";
            };
            options.excludeByName = {
              Time = true;
              __name__ = true;
              job = true;
              peer_os = true;
            };
          }
        ];
        targets = [
          (target {
            expr = ''label_join(avg_over_time(ts:peer_tx_bytes{instance=~"$host"}[15m]), "id", "-to-", "instance", "peer")'';
            format = "table";
            instant = true;
            refId = "edges";
          })
        ];
      })
      (status {
        title = "Traffic between hosts";
        description = "A heatmap-like matrix over time: each row is a source → destination tailnet pair and colour is throughput. This is total peer traffic; protocol-level splits such as SSH need flow telemetry that node_exporter and Tailscale do not expose.";
        w = 24;
        h = 11;
        unit = "Bps";
        min = 0;
        targets = [
          (target {
            expr = ''avg_over_time(ts:peer_tx_bytes{instance=~"$host"}[15m])'';
            legend = "{{instance}} → {{peer}}";
            interval = "15m";
            maxDataPoints = 700;
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
            expr = ''avg_over_time(ts:peer_tx_bytes{instance=~"$host"}[$smooth])'';
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
            expr = ''avg_over_time(ts:peer_tx_bytes{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} to {{peer}}";
          })
          (target {
            expr = ''avg_over_time(ts:peer_rx_bytes{instance=~"$host"}[$smooth])'';
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
            expr = ''avg_over_time(ts:path_bytes{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} {{path}}";
          })
        ];
      })
      (timeline {
        title = "Peer connection type";
        mappings = directMappings;
        targets = [
          (target {
            expr = ''avg_over_time(ts:peer_direct{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} to {{peer}}";
          })
        ];
      })
      (table {
        title = "WireGuard handshake age";
        description = "A tunnel can be up and still pass no return traffic. Handshake age climbing while bytes flow one way is the signature of two hosts sharing one Proton credential.";
        unit = "s";
        targets = [
          (target {
            expr = ''(wg:handshake_age_seconds_max{instance=~"$host"} or wg:handshake_age_seconds{instance=~"$host"})'';
            legend = "{{instance}} {{interface}}";
            format = "table";
            instant = true;
          })
        ];
      })
      (ts {
        title = "WireGuard received";
        unit = "Bps";
        targets = [
          (target {
            expr = ''avg_over_time(wg:rx_bytes{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} {{interface}}";
          })
        ];
      })
      (ts {
        title = "WireGuard sent";
        unit = "Bps";
        targets = [
          (target {
            expr = ''avg_over_time(wg:tx_bytes{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} {{interface}}";
          })
        ];
      })
    ];
  };

  historyFleet = dashboard {
    uid = "fleet";
    title = "Fleet and connectivity";
    datasource = "prometheus-lt";
    from = "now-7d";
    refresh = "1m";
    tags = [ "history" ];
    variables = [
      (fleetHostVariable "prometheus-lt")
      smoothVariable
    ];
    links = [
      (presetLink "Live" "fleet" "now-15m" "5s")
      (presetLink "24h" "fleet" "now-24h" "1m")
      (presetLink "7d" "fleet" "now-7d" "5m")
      (presetLink "30d" "fleet" "now-30d" "5m")
      (dashboardLink "System" "system")
      (dashboardLink "Network" "network")
      (dashboardLink "Uptime archive" "archive-uptime")
    ];
    panels = [
      (stat {
        title = "Hosts up";
        w = 6;
        h = 5;
        targets = [
          (target {
            expr = "count(host:up == 1)";
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
            expr = "count(max by (peer) (ts:peer_online) == 1)";
            instant = true;
          })
        ];
      })
      (stat {
        title = "System uptime";
        w = 12;
        h = 5;
        unit = "s";
        decimals = 1;
        targets = [
          (target {
            expr = ''time() - max by (instance) ((host:boot_time_seconds_max{instance=~"$host"} or host:boot_time_seconds{instance=~"$host"}))'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (table {
        title = "Devices";
        description = "Current tailnet inventory, ordered with offline devices first. Online state is colour-coded and handshake age highlights stale peers.";
        w = 24;
        h = 9;
        options = {
          showHeader = true;
          cellHeight = "sm";
          footer.show = false;
        };
        overrides = [
          {
            matcher = {
              id = "byName";
              options = "Online";
            };
            properties = [
              {
                id = "mappings";
                value = upMappings;
              }
              {
                id = "custom.cellOptions";
                value = {
                  type = "color-background";
                  mode = "basic";
                };
              }
              {
                id = "custom.width";
                value = 100;
              }
            ];
          }
          {
            matcher = {
              id = "byName";
              options = "Handshake age";
            };
            properties = [
              {
                id = "unit";
                value = "s";
              }
            ];
          }
        ];
        transformations = [
          {
            id = "joinByField";
            options = {
              byField = "peer";
              mode = "outer";
            };
          }
          {
            id = "organize";
            options.renameByName = {
              peer = "Device";
              peer_os = "OS";
              relay = "Relay";
              "Value #A" = "Online";
              "Value #B" = "Handshake age";
            };
            options.excludeByName = {
              Time = true;
              __name__ = true;
              job = true;
              instance = true;
            };
          }
          {
            id = "sortBy";
            options.sort = [
              {
                field = "Online";
                desc = false;
              }
            ];
          }
        ];
        targets = [
          (target {
            expr = "max by (peer, peer_os, relay) (ts:peer_online)";
            format = "table";
            instant = true;
          })
          (target {
            expr = "max by (peer) ((ts:handshake_age_seconds_max or ts:handshake_age_seconds))";
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
        color = upColor;
        min = 0;
        max = 1;
        targets = [
          (target {
            expr = ''max by (instance) (host:up${upSelector})'';
            legend = "{{instance}}";
          })
        ];
      })
    ];
  };

  historySystem = dashboard {
    uid = "system";
    title = "System";
    datasource = "prometheus-lt";
    from = "now-7d";
    refresh = "5m";
    tags = [ "history" ];
    variables = [
      (hostVariable "prometheus-lt")
      (capacityVariable "prometheus-lt")
      smoothVariable
    ];
    links = [
      (presetLink "Live" "system" "now-15m" "5s")
      (presetLink "24h" "system" "now-24h" "1m")
      (presetLink "7d" "system" "now-7d" "5m")
      (presetLink "30d" "system" "now-30d" "5m")
      (dashboardLink "Power and thermals" "power")
      (dashboardLink "Capacity archive" "archive-capacity")
    ];
    panels = [
      (ts {
        title = "CPU utilisation";
        w = 24;
        unit = "percentunit";
        max = 1;
        min = 0;
        overrides = [ (dimmed ".*peak$") ];
        targets = [
          (target {
            expr = ''avg_over_time(cpu:utilisation{instance=~"$host"}[$smooth])'';
            legend = "{{instance}}";
          })
          (target {
            expr = ''max_over_time((cpu:utilisation_max{instance=~"$host"} or cpu:utilisation{instance=~"$host"})[$smooth:])'';
            legend = "{{instance}} peak";
          })
        ];
      })
      (ts {
        title = "Load pressure";
        description = "Load average is the one-minute average number of runnable tasks plus tasks waiting in uninterruptible I/O. This divides it by each host's logical CPU count: 100% means one task per CPU; higher values mean work is queueing.";
        unit = "percentunit";
        targets = [
          (target {
            expr = ''avg_over_time(load:pressure_ratio{instance=~"$host"}[$smooth])'';
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
            expr = ''(mem:total_bytes_max{instance=~"$host"} or mem:total_bytes{instance=~"$host"})'';
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
            expr = ''max_over_time((mem:used_ratio_max{instance=~"$host"} or mem:used_ratio{instance=~"$host"})[$__range:])'';
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
            expr = ''avg_over_time(mem:used_bytes{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} used";
          })
          (target {
            expr = ''max_over_time((mem:used_bytes_max{instance=~"$host"} or mem:used_bytes{instance=~"$host"})[$smooth:])'';
            legend = "{{instance}} peak";
          })
          (target {
            expr = ''(mem:total_bytes_max{instance=~"$host"} or mem:total_bytes{instance=~"$host"})'';
            legend = "{{instance}} capacity";
          })
        ];
      })
      (ts {
        title = "Memory — $capacity machines";
        w = 12;
        h = 8;
        unit = "bytes";
        min = 0;
        repeat = "capacity";
        repeatDirection = "h";
        maxPerRow = 2;
        targets = [
          (target {
            expr = ''avg_over_time(mem:used_bytes[$smooth]) * on(instance) group_left(capacity) (mem:capacity_info_max{capacity=~"$capacity"} or mem:capacity_info{capacity=~"$capacity"})'';
            legend = "{{instance}}";
          })
          (target {
            expr = ''max_over_time((mem:used_bytes_max or mem:used_bytes)[$smooth:]) * on(instance) group_left(capacity) (mem:capacity_info_max{capacity=~"$capacity"} or mem:capacity_info{capacity=~"$capacity"})'';
            legend = "{{instance}} peak";
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
            expr = ''avg_over_time(mem:used_ratio{instance=~"$host"}[$smooth])'';
            legend = "{{instance}}";
          })
          (target {
            expr = ''max_over_time((mem:used_ratio_max{instance=~"$host"} or mem:used_ratio{instance=~"$host"})[$smooth:])'';
            legend = "{{instance}} peak";
          })
        ];
      })
      (ts {
        title = "Swap — $capacity machines";
        unit = "bytes";
        min = 0;
        repeat = "capacity";
        repeatDirection = "h";
        maxPerRow = 2;
        overrides = [ (dimmed ".*capacity$") ];
        targets = [
          (target {
            expr = ''avg_over_time(mem:swap_used_bytes[$smooth]) * on(instance) group_left(capacity) (mem:capacity_info_max{capacity=~"$capacity"} or mem:capacity_info{capacity=~"$capacity"})'';
            legend = "{{instance}}";
          })
          (target {
            expr = ''(mem:swap_total_bytes_max or mem:swap_total_bytes) * on(instance) group_left(capacity) (mem:capacity_info_max{capacity=~"$capacity"} or mem:capacity_info{capacity=~"$capacity"})'';
            legend = "{{instance}} capacity";
          })
        ];
      })
      (ts {
        title = "Pressure stall";
        unit = "percentunit";
        targets = [
          (target {
            expr = ''avg_over_time(psi:cpu_waiting{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} cpu";
          })
          (target {
            expr = ''avg_over_time(psi:io_stalled{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} io";
          })
          (target {
            expr = ''avg_over_time(psi:memory_stalled{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} memory";
          })
        ];
      })
      (ts {
        title = "Disk throughput";
        unit = "Bps";
        targets = [
          (target {
            expr = ''avg_over_time(disk:read_bytes{instance=~"$host"}[$smooth])'';
            legend = "{{instance}} {{device}} read";
          })
          (target {
            expr = ''avg_over_time(disk:written_bytes{instance=~"$host"}[$smooth])'';
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
            expr = ''avg_over_time(cpu:throttled_ratio{instance=~"$host"}[$smooth])'';
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
            expr = ''min_over_time((fs:free_ratio_min{instance=~"$host"} or fs:free_ratio{instance=~"$host"})[$smooth:])'';
            legend = "{{instance}} {{mountpoint}}";
          })
        ];
      })
      (stat {
        title = "Days until full";
        description = "Linear extrapolation appears only while free space has a measurable downward trend; flat and growing filesystems are shown as stable.";
        unit = "d";
        decimals = 1;
        mappings = [
          {
            type = "special";
            options = {
              match = "null";
              result = {
                text = "Stable";
                color = "green";
              };
            };
          }
        ];
        targets = [
          (target {
            expr = ''clamp_max((fs:avail_bytes_min{instance=~"$host"} or fs:avail_bytes{instance=~"$host"}) / -deriv((fs:avail_bytes_min{instance=~"$host"} or fs:avail_bytes{instance=~"$host"})[7d:]) / 86400, 3650) and (deriv((fs:avail_bytes_min{instance=~"$host"} or fs:avail_bytes{instance=~"$host"})[7d:]) < -1)'';
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
            expr = ''max_over_time((systemd:failed_units_max{instance=~"$host"} or systemd:failed_units{instance=~"$host"})[$smooth:])'';
            legend = "{{instance}}";
          })
        ];
      })
      (ts {
        title = "Prometheus tier health";
        description = "Head series in each tier. A hi-res tier that stops growing, or scrape durations approaching the interval, means the one-second scrape is no longer keeping up.";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        targets = [
          (target {
            expr = "prometheus_tsdb_head_series";
            legend = "{{instance}} {{tier}} series";
          })
          (target {
            expr = "rate(prometheus_tsdb_head_samples_appended_total[5m])";
            legend = "{{instance}} {{tier}} samples/s";
          })
        ];
      })
      (ts {
        title = "Scrape duration";
        unit = "s";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        targets = [
          (target {
            expr = "scrape_duration_seconds";
            legend = "{{instance}} {{tier}} {{job}}";
          })
        ];
      })
      (ts {
        title = "Major temperatures";
        description = "Use this beside CPU, memory and I/O charts to correlate workload with thermal response.";
        w = 24;
        h = 9;
        unit = "celsius";
        targets = smoothedMajorTemperatureTargets;
      })
    ];
  };

  # Archive folder: hourly aggregates, kept indefinitely.

  reflow =
    ownUid: p:
    let
      shed = x: if (x.datasource.uid or null) == ownUid then removeAttrs x [ "datasource" ] else x;
    in
    (removeAttrs (shed p) [
      "gridPos"
      "id"
    ])
    // { inherit (p.gridPos) w h; }
    // lib.optionalAttrs (p ? targets) { targets = map shed p.targets; };

  withoutBanner = lib.filter (p: p.type != "text");

  mergedPanels =
    live: history:
    let
      livePanelSet = withoutBanner live.panels;
      liveTitles = map (p: p.title or "") livePanelSet;
      extra = lib.filter (p: !(lib.elem (p.title or "") liveTitles)) (withoutBanner history.panels);
    in
    map (reflow "prometheus") livePanelSet ++ map (reflow "prometheus-lt") extra;

  tierLink = title: uid: from: seconds: refresh: res: {
    inherit title;
    type = "link";
    url = "/d/${uid}?from=${from}&to=now&var-res=${res}&var-smooth=${smoothFor seconds}&refresh=${refresh}";
    includeVars = false;
    keepTime = false;
    targetBlank = false;
  };

  tierLinks = uid: [
    (tierLink "Live" uid "now-15m" 900 "5s" "prometheus")
    (tierLink "24h" uid "now-24h" 86400 "1m" "prometheus-lt")
    (tierLink "7d" uid "now-7d" 604800 "5m" "prometheus-lt")
    (tierLink "30d" uid "now-30d" 2592000 "5m" "prometheus-lt")
    (tierLink "1y" uid "now-1y" 31536000 "" "prometheus-archive")
  ];

  mergedPower = dashboard {
    uid = "power";
    title = "Power and thermals";
    datasource = "\${res}";
    from = "now-15m";
    refresh = "5s";
    tags = [ "metrics" ];
    variables = [
      resolutionVariable
      (hostVariable "prometheus")
      (sensorVariable "prometheus")
      smoothVariable
      tariffVariable
    ];
    links = tierLinks "power" ++ [
      (dashboardLink "System" "system")
      (dashboardLink "Network" "network")
      (dashboardLink "Fleet" "fleet")
      (dashboardLink "Overview" "overview")
    ];
    panels = mergedPanels livePower historyPower;
  };

  mergedSystem = dashboard {
    uid = "system";
    title = "System";
    datasource = "\${res}";
    from = "now-15m";
    refresh = "5s";
    tags = [ "metrics" ];
    variables = [
      resolutionVariable
      (hostVariable "prometheus")
      (capacityVariable "prometheus")
      smoothVariable
    ];
    links = tierLinks "system" ++ [
      (dashboardLink "Power and thermals" "power")
      (dashboardLink "Network" "network")
      (dashboardLink "Fleet" "fleet")
      (dashboardLink "Overview" "overview")
    ];
    panels = mergedPanels liveSystem historySystem;
  };

  mergedNetworkPanels = map (reflow "prometheus-lt") (withoutBanner historyNetwork.panels);

  mergedNetwork = dashboard {
    uid = "network";
    title = "Network";
    datasource = "\${res}";
    from = "now-15m";
    refresh = "5s";
    tags = [ "metrics" ];
    variables = [
      resolutionVariable
      (hostVariable "prometheus")
      smoothVariable
    ];
    links = tierLinks "network" ++ [
      (dashboardLink "System" "system")
      (dashboardLink "Power and thermals" "power")
      (dashboardLink "Overview" "overview")
    ];
    panels = mergedNetworkPanels;
  };

  mergedFleet = dashboard {
    uid = "fleet";
    title = "Fleet";
    datasource = "\${res}";
    from = "now-15m";
    refresh = "5s";
    tags = [ "metrics" ];
    variables = [
      resolutionVariable
      (fleetHostVariable "prometheus")
    ];
    links = tierLinks "fleet" ++ [
      (dashboardLink "System" "system")
      (dashboardLink "Power and thermals" "power")
      (dashboardLink "Overview" "overview")
    ];
    panels = map (reflow "prometheus-lt") (withoutBanner historyFleet.panels);
  };

  archiveEnergy = dashboard {
    uid = "archive-energy";
    title = "Energy";
    datasource = "prometheus-archive";
    from = "now-1y";
    refresh = "";
    tags = [ "archive" ];
    variables = [
      (fleetHostVariable "prometheus-archive")
      smoothVariable
      tariffVariable
    ];
    links = [
      (dashboardLink "Power history" "power")
      (dashboardLink "Overview" "overview")
    ];
    panels = [
      (bar {
        title = "Power draw";
        w = 24;
        h = 8;
        unit = "watt";
        decimals = 0;
        options = {
          xField = "category";
          stacking = "normal";
          showValue = "never";
          xTickLabelRotation = 0;
          legend = {
            displayMode = "list";
            placement = "bottom";
            showLegend = true;
            calcs = [ ];
          };
          tooltip.mode = "multi";
          tooltip.sort = "desc";
        };
        transformations = [
          {
            id = "labelsToFields";
            options = {
              keepLabels = [
                "instance"
                "category"
              ];
              valueLabel = "instance";
            };
          }
          {
            id = "merge";
            options = { };
          }
        ];
        custom = {
          fillOpacity = 80;
          lineWidth = 1;
        };
        targets = [
          (target {
            expr = ''label_replace(last_over_time(pc:power_watts{instance=~"$host"}[2h]), "category", "Latest (1h)", "__name__", ".*")'';
            instant = true;
          })
          (target {
            expr = ''label_replace(avg_over_time(pc:power_watts{instance=~"$host"}[24h]), "category", "Mean (24h)", "__name__", ".*")'';
            instant = true;
          })
          (target {
            expr = ''label_replace(max_over_time((pc:power_watts_max{instance=~"$host"} or pc:power_watts{instance=~"$host"})[24h:]), "category", "Max (24h)", "__name__", ".*")'';
            instant = true;
          })
        ];
      })
      (pie {
        title = "Energy (24h)";
        w = 6;
        h = 5;
        unit = "kwatth";
        decimals = 1;
        targets = [
          (target {
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[24h]) / 1000'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (pie {
        title = "Energy (7d)";
        w = 6;
        h = 5;
        unit = "kwatth";
        decimals = 1;
        targets = [
          (target {
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[7d]) / 1000'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (pie {
        title = "Cost (24h)";
        w = 6;
        h = 5;
        unit = "currencyGBP";
        decimals = 2;
        targets = [
          (target {
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[24h]) / 1000 * ($tariff / 100)'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (pie {
        title = "Cost (7d)";
        w = 6;
        h = 5;
        unit = "currencyGBP";
        decimals = 2;
        targets = [
          (target {
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[7d]) / 1000 * ($tariff / 100)'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (stat {
        title = "Energy over range";
        w = 8;
        h = 5;
        unit = "kwatth";
        decimals = 1;
        targets = [
          (target {
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[$__range]) / 1000'';
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
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[$__range]) / 1000 * ($tariff / 100)'';
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
            expr = ''avg_over_time(pc:power_watts{instance=~"$host"}[$__range])'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (ts {
        title = "Energy use over time";
        description = "Energy use per smoothing interval, stacked by host.";
        w = 24;
        h = 9;
        unit = "kwatth";
        decimals = 2;
        custom = lineCustom // {
          fillOpacity = 45;
          lineWidth = 1;
          stacking = {
            mode = "normal";
            group = "A";
          };
        };
        targets = [
          (target {
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[$smooth]) / 1000'';
            legend = "{{instance}}";
            interval = "$smooth";
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
            datasource = {
              type = "prometheus";
              uid = "prometheus-lt";
            };
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[1d]) / 60 / 1000 * ($tariff / 100)'';
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
            datasource = {
              type = "prometheus";
              uid = "prometheus-lt";
            };
            expr = ''sum_over_time(pc:power_watts{instance=~"$host"}[30d]) / 60 / 1000'';
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
            expr = ''avg_over_time(pc:power_watts{instance=~"$host"}[1d])'';
            legend = "{{instance}}";
            interval = "1d";
          })
          (target {
            expr = ''max_over_time((pc:power_watts_max{instance=~"$host"} or pc:power_watts{instance=~"$host"})[1d:])'';
            legend = "{{instance}} peak";
            interval = "1d";
          })
        ];
      })
    ];
  };

  archiveUptime = dashboard {
    uid = "archive-uptime";
    title = "Tailscale uptime";
    datasource = "prometheus-archive";
    from = "now-1y";
    refresh = "";
    tags = [ "archive" ];
    variables = [ (fleetHostVariable "prometheus-archive") ];
    links = [
      (dashboardLink "Fleet" "fleet")
      (dashboardLink "Overview" "overview")
    ];
    panels = [
      (stat {
        title = "Availability over range";
        w = 12;
        h = 5;
        unit = "percentunit";
        decimals = 4;
        targets = [
          (target {
            expr = ''max by (instance) (avg_over_time(host:up${upSelector}[$__range]))'';
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
            expr = ''(1 - max by (instance) (avg_over_time(host:up${upSelector}[$__range]))) * $__range_s'';
            legend = "{{instance}}";
            instant = true;
          })
        ];
      })
      (bar {
        title = "Tailscale uptime per day";
        description = "Same geometry as the energy-per-day bars, so the two line up when read side by side.";
        w = 24;
        h = 9;
        unit = "percentunit";
        max = 1;
        min = 0;
        decimals = 3;
        targets = [
          (target {
            expr = ''max by (instance) (avg_over_time(host:up${upSelector}[1d]))'';
            legend = "{{instance}}";
            interval = "1d";
          })
        ];
      })
      (bar {
        title = "Tailscale uptime per month";
        w = 12;
        h = 8;
        unit = "percentunit";
        max = 1;
        min = 0;
        decimals = 4;
        targets = [
          (target {
            expr = ''max by (instance) (avg_over_time(host:up${upSelector}[30d]))'';
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
        color = upColor;
        min = 0;
        max = 1;
        targets = [
          (target {
            expr = ''max by (instance) (host:up${upSelector})'';
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
    refresh = "";
    tags = [ "archive" ];
    variables = [ (capacityVariable "prometheus-archive") ];
    links = [
      (dashboardLink "System history" "system")
      (dashboardLink "Overview" "overview")
    ];
    panels = [
      (stat {
        title = "RAM installed";
        w = 8;
        h = 5;
        unit = "bytes";
        decimals = 0;
        targets = [
          (target {
            expr = "(mem:total_bytes_max or mem:total_bytes)";
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
            expr = "(cpu:cores_max or cpu:cores)";
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
            expr = ''sum by (instance) ((fs:size_bytes_max{mountpoint="/"} or fs:size_bytes{mountpoint="/"}))'';
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
            expr = "avg_over_time(mem:used_bytes[1d])";
            legend = "{{instance}} used";
            interval = "1d";
          })
          (target {
            expr = "max_over_time((mem:used_bytes_max or mem:used_bytes)[1d:])";
            legend = "{{instance}} peak";
            interval = "1d";
          })
          (target {
            expr = "max_over_time((mem:total_bytes_max or mem:total_bytes)[1d:])";
            legend = "{{instance}} capacity";
            interval = "1d";
          })
        ];
      })
      (ts {
        title = "Memory — $capacity machines";
        w = 12;
        h = 9;
        unit = "bytes";
        min = 0;
        repeat = "capacity";
        repeatDirection = "h";
        maxPerRow = 2;
        targets = [
          (target {
            expr = ''avg_over_time(mem:used_bytes[1d]) * on(instance) group_left(capacity) (mem:capacity_info_max{capacity=~"$capacity"} or mem:capacity_info{capacity=~"$capacity"})'';
            legend = "{{instance}}";
            interval = "1d";
          })
          (target {
            expr = ''max_over_time((mem:used_bytes_max or mem:used_bytes)[1d:]) * on(instance) group_left(capacity) (mem:capacity_info_max{capacity=~"$capacity"} or mem:capacity_info{capacity=~"$capacity"})'';
            legend = "{{instance}} peak";
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
            expr = "max_over_time((mem:used_ratio_max or mem:used_ratio)[1d:])";
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
            expr = "min_over_time((fs:avail_bytes_min or fs:avail_bytes)[1d:])";
            legend = "{{instance}} {{mountpoint}} free";
            interval = "1d";
          })
          (target {
            expr = "max_over_time((fs:size_bytes_max or fs:size_bytes)[1d:])";
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
    refresh = "";
    tags = [ "archive" ];
    variables = [
      (hostVariable "prometheus-archive")
      (sensorVariable "prometheus-archive")
    ];
    links = [
      (dashboardLink "Thermal history" "power")
      (dashboardLink "Overview" "overview")
    ];
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
            expr = ''avg_over_time(sensor:temp_celsius{instance=~"$host",name=~"$sensor"}[1d])'';
            legend = "{{instance}} {{name}}";
            interval = "1d";
          })
          (target {
            expr = ''max_over_time((sensor:temp_celsius_max{instance=~"$host",name=~"$sensor"} or sensor:temp_celsius{instance=~"$host",name=~"$sensor"})[1d:])'';
            legend = "{{instance}} {{name}} peak";
            interval = "1d";
          })
          (target {
            expr = ''min_over_time((sensor:temp_celsius_min{instance=~"$host",name=~"$sensor"} or sensor:temp_celsius{instance=~"$host",name=~"$sensor"})[1d:])'';
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
            expr = ''max_over_time((sensor:temp_celsius_max{instance=~"$host",name=~"$sensor"} or sensor:temp_celsius{instance=~"$host",name=~"$sensor"})[1d:])'';
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
            expr = ''avg_over_time(fan:rpm{instance=~"$host"}[1d])'';
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
            expr = ''max by (instance) (avg_over_time(fan:rpm{instance=~"$host"}[1d])) / max by (instance) (avg_over_time(sensor:temp_celsius{instance=~"$host",name=~"$sensor"}[1d]))'';
            legend = "{{instance}}";
            interval = "1d";
          })
        ];
      })
    ];
  };

  nixBuilds = dashboard {
    uid = "nix-builds";
    title = "Nix Builds";
    datasource = "loki";
    from = "now-24h";
    refresh = "1m";
    tags = [
      "nix"
      "builds"
    ];
    variables = [
      logHostVariable
      (textboxVariable "project" "Project regex" ".*")
    ];
    links = [
      (dashboardLink "Build detail" "nix-build-detail")
      (dashboardLink "Daily history" "nix-build-history")
      (dashboardLink "Logs" "logs")
      (dashboardLink "Alerts" "alerts")
      (dashboardLink "Overview" "overview")
    ];
    panels = [
      (stat {
        title = "Builds";
        w = 4;
        h = 5;
        targets = [
          (target {
            expr = ''sum(count_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" [$__range]))'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Failures";
        w = 4;
        h = 5;
        targets = [
          (target {
            expr = ''sum(count_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" | status="failed" [$__range]))'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Mean full rebuild time";
        w = 4;
        h = 5;
        unit = "s";
        targets = [
          (target {
            expr = ''avg(avg_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_rebuild" | project=~"$project" | unwrap duration_seconds [$__range]))'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Compiled derivations";
        w = 4;
        h = 5;
        targets = [
          (target {
            expr = ''sum(sum_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" | unwrap compiled [$__range]))'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Substituted paths";
        w = 4;
        h = 5;
        targets = [
          (target {
            expr = ''sum(sum_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" | unwrap substituted [$__range]))'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Cache ratio";
        w = 4;
        h = 5;
        unit = "percentunit";
        min = 0;
        max = 1;
        targets = [
          (target {
            expr = ''sum(sum_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" | unwrap substituted [$__range])) / sum(sum_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" | unwrap required [$__range]))'';
            instant = true;
          })
        ];
      })
      (bar {
        title = "Build duration (5-minute buckets)";
        w = 24;
        h = 9;
        unit = "s";
        targets = [
          (target {
            expr = ''max_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" | unwrap duration_seconds [5m])'';
            legend = "{{host}} {{project}} {{kind}} {{status}}";
            interval = "5m";
            maxDataPoints = 300;
          })
        ];
      })
      (logs {
        title = "Build and rebuild history";
        w = 24;
        h = 13;
        targets = [
          (target {
            expr = ''{service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" | line_format "{{.status}}  {{.project}}  {{.kind}}  {{.duration_seconds}}s  required={{.required}} compiled={{.compiled}} substituted={{.substituted}} closure={{.closure_paths}}/{{.closure_nar_bytes}}B failed={{.failed_package}} trace={{.trace_id}}"'';
          })
        ];
      })
      (logs {
        title = "Failed package output";
        w = 24;
        h = 12;
        targets = [
          (target {
            expr = ''{service_name="nix-observer",host=~"$host"} | json | event="nix_build_log" | project=~"$project" | line_format "{{.project}} {{.package}}: {{.message}} trace={{.trace_id}}"'';
          })
        ];
      })
    ];
  };

  nixBuildHistory = dashboard {
    uid = "nix-build-history";
    title = "Nix Build History";
    datasource = "loki";
    from = "now-90d";
    refresh = "";
    tags = [
      "nix"
      "builds"
      "history"
    ];
    variables = [
      logHostVariable
      (textboxVariable "project" "Project regex" ".*")
    ];
    links = [
      (dashboardLink "Recent builds" "nix-builds")
      (dashboardLink "Build detail" "nix-build-detail")
      (dashboardLink "Overview" "overview")
    ];
    panels = [
      (bar {
        title = "Builds per day";
        w = 12;
        h = 9;
        targets = [
          (target {
            expr = ''sum by (host) (count_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" [1d]))'';
            legend = "{{host}}";
            interval = "1d";
            maxDataPoints = 100;
          })
        ];
      })
      (bar {
        title = "Failures per day";
        w = 12;
        h = 9;
        targets = [
          (target {
            expr = ''sum by (host) (count_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" | status="failed" [1d]))'';
            legend = "{{host}}";
            interval = "1d";
            maxDataPoints = 100;
          })
        ];
      })
      (ts {
        title = "Daily build duration";
        w = 24;
        h = 10;
        unit = "s";
        targets = [
          (target {
            expr = ''avg by (host) (avg_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" | unwrap duration_seconds [1d]))'';
            legend = "{{host}} mean";
            interval = "1d";
            maxDataPoints = 100;
          })
          (target {
            expr = ''max by (host) (max_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" | unwrap duration_seconds [1d]))'';
            legend = "{{host}} max";
            interval = "1d";
            maxDataPoints = 100;
          })
          (target {
            expr = ''avg by (host) (avg_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_rebuild" | project=~"$project" | unwrap duration_seconds [1d]))'';
            legend = "{{host}} full rebuild mean";
            interval = "1d";
            maxDataPoints = 100;
          })
        ];
      })
      (bar {
        title = "Compiled paths per day";
        w = 12;
        h = 9;
        targets = [
          (target {
            expr = ''sum by (host) (sum_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" | unwrap compiled [1d]))'';
            legend = "{{host}}";
            interval = "1d";
            maxDataPoints = 100;
          })
        ];
      })
      (bar {
        title = "Substituted paths per day";
        w = 12;
        h = 9;
        targets = [
          (target {
            expr = ''sum by (host) (sum_over_time({service_name="nix-observer-summary",host=~"$host"} | json | event="nix_build" | project=~"$project" | unwrap substituted [1d]))'';
            legend = "{{host}}";
            interval = "1d";
            maxDataPoints = 100;
          })
        ];
      })
    ];
  };

  nixBuildDetail = dashboard {
    uid = "nix-build-detail";
    title = "Nix Build Detail";
    datasource = "loki";
    from = "now-6h";
    refresh = "30s";
    tags = [
      "nix"
      "builds"
    ];
    variables = [ (textboxVariable "trace" "Trace ID" ".*") ];
    links = [
      (dashboardLink "All builds" "nix-builds")
      (dashboardLink "System" "system")
      (dashboardLink "Logs" "logs")
    ];
    panels = [
      (logs {
        title = "Invocation";
        w = 24;
        h = 6;
        targets = [
          (target {
            expr = ''{service_name="nix-observer-summary"} | json | event="nix_build" | trace_id=~"$trace"'';
          })
        ];
      })
      (logs {
        title = "Required workset — compiled and substituted";
        w = 24;
        h = 14;
        targets = [
          (target {
            expr = ''{service_name="nix-observer"} | json | event="nix_derivation" | trace_id=~"$trace" | line_format "{{.status}}  {{.classification}}  {{.package}}  {{.duration_seconds}}s  phase={{.phase}}  {{.derivation}}"'';
          })
        ];
      })
      (logs {
        title = "Failure output";
        w = 24;
        h = 16;
        targets = [
          (target {
            expr = ''{service_name="nix-observer"} | json | event="nix_build_log" | trace_id=~"$trace" | line_format "{{.package}}: {{.message}}"'';
          })
        ];
      })
    ];
  };

  logsExplorer = dashboard {
    uid = "logs";
    title = "Fleet Logs";
    datasource = "loki";
    from = "now-6h";
    refresh = "30s";
    tags = [ "logs" ];
    variables = [
      logHostVariable
      (textboxVariable "search" "Message regex" ".*")
    ];
    links = [
      (dashboardLink "Nix builds" "nix-builds")
      (dashboardLink "Alerts" "alerts")
      (dashboardLink "Overview" "overview")
    ];
    panels = [
      (stat {
        title = "Errors and worse";
        w = 6;
        h = 5;
        targets = [
          (target {
            expr = ''sum(count_over_time({source="journal",host=~"$host",level=~"emerg|alert|crit|err"} [$__range]))'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "OOM / kernel failures";
        w = 6;
        h = 5;
        targets = [
          (target {
            expr = ''sum(count_over_time({source="journal",host=~"$host"} |~ "(?i)out of memory|oom-kill|kernel panic" [$__range]))'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Tailscale / VPN failures";
        w = 6;
        h = 5;
        targets = [
          (target {
            expr = ''sum(count_over_time({source="journal",host=~"$host",unit=~"tailscaled.service|wg-quick-.*"} |~ "(?i)error|failed|timeout|disconnected" [$__range]))'';
            instant = true;
          })
        ];
      })
      (stat {
        title = "Failed Nix builds";
        w = 6;
        h = 5;
        targets = [
          (target {
            expr = ''sum(count_over_time({service_name="nix-observer-summary",host=~"$host"} | json | status="failed" [$__range]))'';
            instant = true;
          })
        ];
      })
      (logs {
        title = "Journal";
        w = 24;
        h = 20;
        targets = [
          (target {
            expr = ''{source="journal",host=~"$host"} |~ "$search"'';
          })
        ];
      })
    ];
  };
in

{
  overview = {
    "home.json" = overview;
    "alerts.json" = alerts;
  };

  metrics = {
    "power.json" = mergedPower;
    "system.json" = mergedSystem;
    "network.json" = mergedNetwork;
    "fleet.json" = mergedFleet;
  };

  archive = {
    "energy.json" = archiveEnergy;
    "uptime.json" = archiveUptime;
    "thermal.json" = archiveThermal;
    "capacity.json" = archiveCapacity;
  };

  observability = {
    "nix-builds.json" = nixBuilds;
    "nix-build-history.json" = nixBuildHistory;
    "nix-build-detail.json" = nixBuildDetail;
    "logs.json" = logsExplorer;
  };
}

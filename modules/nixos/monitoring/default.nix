# Metrics: node_exporter everywhere, three Prometheus tiers and Grafana on the server.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.monitoring;

  rules = import ./rules.nix { inherit config lib; };
  dashboards = import ./dashboards.nix { inherit lib; };

  yaml = pkgs.formats.yaml { };
  json = pkgs.formats.json { };

  hiresPort = config.services.prometheus.port;
  longtermPort = 9091;
  archivePort = 9092;
  powerStatePort = 9093;

  powerStateReporter = pkgs.writeShellApplication {
    name = "report-power-state";
    runtimeInputs = [ pkgs.curl ];
    text = ''
      state="$1"
      case "$state" in
        running|S3|S5) ;;
        *) exit 2 ;;
      esac
      printf 'host_power_state{state="%s"} 1\n' "$state" \
        | curl --fail --silent --show-error --max-time 5 --retry 2 \
          --data-binary @- \
          "http://${config.local.monitoring.telemetry.serverAddress}:${toString powerStatePort}/metrics/job/host_power_state/instance/${config.networking.hostName}"
    '';
  };

  ruleFile = name: groups: yaml.generate "${name}.yml" { inherit groups; };

  tierConfig =
    {
      from,
      match,
      interval,
      groups,
    }:
    yaml.generate "prometheus-${toString from}-federate.yml" {
      global = {
        scrape_interval = interval;
        scrape_timeout = "30s";
        evaluation_interval = interval;
      };
      rule_files = lib.optional (groups != [ ]) "${ruleFile "tier-rules" groups}";
      scrape_configs = [
        {
          job_name = "federate";
          honor_labels = true;
          metrics_path = "/federate";
          params."match[]" = [ match ];
          static_configs = [ { targets = [ "127.0.0.1:${toString from}" ]; } ];
        }
      ];
    };

  mkTier =
    {
      name,
      port,
      retention,
      from,
      match,
      interval,
      groups ? [ ],
    }:
    {
      description = "Prometheus ${name} tier";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "prometheus.service"
      ];
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.prometheus}/bin/prometheus"
          "--config.file=${
            tierConfig {
              inherit
                from
                match
                interval
                groups
                ;
            }
          }"
          "--storage.tsdb.path=/var/lib/prometheus-${name}"
          "--storage.tsdb.retention.time=${retention}"
          "--storage.tsdb.retention.size=0"
          "--web.listen-address=127.0.0.1:${toString port}"
          "--web.enable-lifecycle"
        ];
        DynamicUser = true;
        StateDirectory = "prometheus-${name}";
        Restart = "always";
        RestartSec = "10s";
      };
    };

  datasource = name: uid: port: {
    inherit name uid;
    type = "prometheus";
    access = "proxy";
    url = "http://127.0.0.1:${toString port}";
    isDefault = uid == "prometheus-lt";
    jsonData = {
      timeInterval = if uid == "prometheus" then "1s" else "1m";
      prometheusType = "Prometheus";
    };
  };

  lokiDatasource = {
    name = "Loki";
    uid = "loki";
    type = "loki";
    access = "proxy";
    url = "http://127.0.0.1:3100";
    jsonData = {
      manageAlerts = true;
      maxLines = 5000;
      derivedFields = [
        {
          name = "TraceID";
          matcherRegex = ''"trace_id":"([0-9a-f]{32})"'';
          datasourceUid = "tempo";
          url = "\${__value.raw}";
          urlDisplayLabel = "View build trace";
        }
      ];
    };
  };

  tempoDatasource = {
    name = "Tempo";
    uid = "tempo";
    type = "tempo";
    access = "proxy";
    url = "http://127.0.0.1:3200";
    jsonData = {
      nodeGraph.enabled = true;
      search.hide = false;
      streamingEnabled = {
        search = true;
        metrics = true;
      };
      tracesToLogsV2 = {
        datasourceUid = "loki";
        spanStartTimeShift = "-2s";
        spanEndTimeShift = "2s";
        filterByTraceID = true;
        filterBySpanID = false;
        customQuery = true;
        query = ''{service_name=~"nix-observer.*"} | json | trace_id="''${__trace.traceId}"'';
      };
    };
  };

  dashboardDir =
    folder:
    pkgs.linkFarm "grafana-dashboards-${folder}" (
      lib.mapAttrsToList (name: value: {
        inherit name;
        path = json.generate name value;
      }) dashboards.${folder}
    );

  dashboardProvider = name: folder: {
    inherit name folder;
    orgId = 1;
    type = "file";
    options.path = dashboardDir name;
    allowUiUpdates = false;
  };
in

{
  imports = [
    ./telemetry.nix
    ./textfile.nix
  ];

  options.local.monitoring = {
    exporter.enable = lib.mkEnableOption "node_exporter and its textfile collectors";

    server.enable = lib.mkEnableOption "the Prometheus tiers";

    grafana.enable = lib.mkEnableOption "Grafana with the provisioned dashboards";

    piFirmware.enable = lib.mkEnableOption "Raspberry Pi firmware and PMIC telemetry";

    laptopTelemetry.enable = lib.mkEnableOption "laptop battery and platform telemetry";

    # Linux 5.10 made these root-only over the PLATYPUS side channel; without
    # this the rapl collector sees nothing.
    userReadable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Relax RAPL energy counters to the powermon group.";
    };

    sensorNames = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "k10temp:temp1" = "CPU Tctl";
      };
      description = "Map of \"chip:sensor\" to the caption shown on graphs.";
    };

    targets = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        pi = "100.117.13.66:9100";
      };
      description = "Extra node_exporter instances to scrape, keyed by instance label.";
    };

    totalPower = {
      wallEstimateWatts = lib.mkOption {
        type = lib.types.nullOr lib.types.number;
        default = null;
        description = "Explicit estimated wall draw when no whole-device meter exists.";
      };

      baselineWatts = lib.mkOption {
        type = lib.types.number;
        default = 20.88;
        description = "Modelled draw of RAM, drives, fans and board with no telemetry.";
      };

      psuEfficiency = lib.mkOption {
        type = lib.types.number;
        default = 0.88;
        description = "Assumed PSU conversion efficiency, turning DC draw into wall draw.";
      };

      tariffPencePerKwh = lib.mkOption {
        type = lib.types.number;
        default = 25;
        description = "Electricity price used for the cost panels.";
      };
    };

    retention = {
      hires = lib.mkOption {
        type = lib.types.str;
        default = "3h";
        description = "How long the 1-second tier is kept.";
      };

      longterm = lib.mkOption {
        type = lib.types.str;
        default = "2y";
        description = "How long the 1-minute tier is kept.";
      };
    };

    alerts = {
      cpuTempCelsius = lib.mkOption {
        type = lib.types.number;
        default = 85;
        description = "CPU temperature that raises a warning.";
      };
      cpuCriticalCelsius = lib.mkOption {
        type = lib.types.number;
        default = 95;
        description = "CPU temperature that raises a critical alert.";
      };
      gpuTempCelsius = lib.mkOption {
        type = lib.types.number;
        default = 90;
        description = "GPU temperature that raises a warning.";
      };
      nvmeTempCelsius = lib.mkOption {
        type = lib.types.number;
        default = 70;
        description = "NVMe temperature that raises a warning.";
      };
      vrmTempCelsius = lib.mkOption {
        type = lib.types.number;
        default = 100;
        description = "Board VRM temperature that raises a warning.";
      };
      powerWatts = lib.mkOption {
        type = lib.types.number;
        default = 400;
        description = "Sustained total draw that raises a warning.";
      };
      filesystemFreeRatio = lib.mkOption {
        type = lib.types.number;
        default = 0.1;
        description = "Free space fraction below which a filesystem alerts.";
      };
    };
  };

  config = lib.mkMerge [
    {
      warnings =
        lib.optional (cfg.exporter.enable && cfg.sensorNames == { })
          "local.monitoring.exporter is enabled with no sensorNames, so hwmon graphs will show raw chip:sensor labels.";
    }

    (lib.mkIf cfg.exporter.enable {
      services.prometheus.exporters.node = {
        enable = true;
        listenAddress = "0.0.0.0";
        enabledCollectors = [
          "hwmon"
          "cpufreq"
          "thermal_zone"
          "textfile"
          "systemd"
          "pressure"
        ]
        ++ lib.optionals pkgs.stdenv.hostPlatform.isx86 [ "rapl" ];
      };

      networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
        config.services.prometheus.exporters.node.port
      ];

      environment.etc."systemd/system-sleep/report-power-state" = {
        mode = "0755";
        source = pkgs.writeShellScript "report-power-state-sleep" ''
          case "$1" in
            pre) ${powerStateReporter}/bin/report-power-state S3 ;;
            post) ${powerStateReporter}/bin/report-power-state running ;;
          esac
        '';
      };

      systemd.services.report-power-state-running = {
        description = "Report that this host is running";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "tailscaled.service" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${powerStateReporter}/bin/report-power-state running";
          Restart = "on-failure";
          RestartSec = "15s";
        };
      };

      powerManagement.powerDownCommands = lib.mkAfter ''
        ${powerStateReporter}/bin/report-power-state S5 || true
      '';
    })

    (lib.mkIf (cfg.exporter.enable && !cfg.server.enable) {
      services.vmagent = {
        enable = true;
        remoteWrite.url = "http://${cfg.telemetry.serverAddress}:${toString hiresPort}/api/v1/write";
        extraArgs = [ "-remoteWrite.maxDiskUsagePerURL=2GB" ];
        prometheusConfig = {
          global = {
            scrape_interval = "5s";
            scrape_timeout = "4s";
          };
          scrape_configs = [
            {
              job_name = "node";
              static_configs = [
                {
                  targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
                  labels.instance = config.networking.hostName;
                }
              ];
            }
          ];
        };
      };
    })

    # node_exporter runs as its own user, so it needs the group too.
    (lib.mkIf cfg.userReadable {
      users.groups.powermon = { };
      users.users.max.extraGroups = [ "powermon" ];

      services.udev.extraRules = ''
        SUBSYSTEM=="powercap", ACTION=="add", RUN+="${pkgs.coreutils}/bin/chgrp -R powermon /sys%p", RUN+="${pkgs.coreutils}/bin/chmod -R g=u /sys%p"
      '';

      systemd.services.powercap-permissions = {
        description = "Allow the powermon group to read energy counters";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-modules-load.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          for energy in /sys/class/powercap/*/energy_uj; do
            [ -e "$energy" ] || continue
            chgrp powermon "$energy"
            chmod g+r "$energy"
          done
        '';
      };

      systemd.services.prometheus-node-exporter.serviceConfig.SupplementaryGroups = [ "powermon" ];
    })

    (lib.mkIf cfg.server.enable {
      services.prometheus = {
        enable = true;
        extraFlags = [ "--web.enable-remote-write-receiver" ];
        listenAddress = "0.0.0.0";
        retentionTime = cfg.retention.hires;
        globalConfig = {
          scrape_interval = "1s";
          scrape_timeout = "900ms";
          evaluation_interval = "15s";
        };
        ruleFiles = [ (ruleFile "hires-rules" rules.hires) ];
        scrapeConfigs = [
          {
            job_name = "power-state";
            honor_labels = true;
            static_configs = [ { targets = [ "127.0.0.1:${toString powerStatePort}" ]; } ];
          }
          {
            job_name = "node";
            static_configs = [
              {
                targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
                labels.instance = config.networking.hostName;
              }
            ];
          }
          {
            job_name = "prometheus";
            scrape_interval = "15s";
            static_configs = [
              {
                targets = [ "127.0.0.1:${toString hiresPort}" ];
                labels = {
                  instance = config.networking.hostName;
                  tier = "hires";
                };
              }
              {
                targets = [ "127.0.0.1:${toString longtermPort}" ];
                labels = {
                  instance = config.networking.hostName;
                  tier = "history";
                };
              }
              {
                targets = [ "127.0.0.1:${toString archivePort}" ];
                labels = {
                  instance = config.networking.hostName;
                  tier = "archive";
                };
              }
            ];
          }
        ];
      };

      services.prometheus.pushgateway = {
        enable = true;
        persistMetrics = true;
        web.listen-address = "0.0.0.0:${toString powerStatePort}";
      };

      networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
        config.services.prometheus.port
        powerStatePort
      ];

      systemd.services.prometheus-longterm = mkTier {
        name = "longterm";
        port = longtermPort;
        retention = cfg.retention.longterm;
        from = hiresPort;
        interval = "60s";
        match = ''{__name__=~"(avg|max|min)1m:.*"}'';
        groups = rules.hourly;
      };

      # Prometheus reads a retention of 0 as "use the 15 day default", so
      # indefinite has to be spelled as a length nothing will outlive.
      systemd.services.prometheus-archive = mkTier {
        name = "archive";
        port = archivePort;
        retention = "100y";
        from = longtermPort;
        interval = "1h";
        match = ''{__name__=~"(avg|max|min)1h:.*"}'';
      };

    })

    (lib.mkIf cfg.grafana.enable {
      sops.secrets."grafana-secret-key".owner = "grafana";
      systemd.services.grafana = {
        after = [ "sops-install-secrets.service" ];
        wants = [ "sops-install-secrets.service" ];
      };

      networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 3000 ];

      services.grafana = {
        enable = true;
        declarativePlugins = [
          pkgs.grafanaPlugins.grafana-exploretraces-app
          pkgs.grafanaPlugins.grafana-lokiexplore-app
          pkgs.grafanaPlugins.grafana-metricsdrilldown-app
        ];
        settings.server = {
          http_addr = "0.0.0.0";
          http_port = 3000;
        };
        settings.dashboards.default_home_dashboard_path = "${dashboardDir "overview"}/home.json";
        settings.security.secret_key = "$__file{${config.sops.secrets."grafana-secret-key".path}}";
        settings."unified_alerting.state_history" = {
          enabled = true;
          backend = "loki";
          loki_remote_url = "http://127.0.0.1:3100";
        };
        settings.feature_toggles.enable = "alertingCentralAlertHistory";
        settings."auth.anonymous" = {
          enabled = true;
          org_role = "Admin";
        };

        provision.datasources.settings = {
          apiVersion = 1;
          datasources = [
            (datasource "Prometheus (1s)" "prometheus" hiresPort)
            (datasource "Prometheus (1m)" "prometheus-lt" longtermPort)
            (datasource "Prometheus (1h)" "prometheus-archive" archivePort)
            lokiDatasource
            tempoDatasource
          ];
        };

        provision.dashboards.settings = {
          apiVersion = 1;
          providers = [
            (dashboardProvider "overview" "Overview")
            (dashboardProvider "live" "Live")
            (dashboardProvider "history" "History")
            (dashboardProvider "archive" "Archive")
            (dashboardProvider "observability" "Observability")
          ];
        };

        provision.alerting.rules.settings = {
          apiVersion = 1;
          groups = [
            {
              orgId = 1;
              name = "thresholds";
              folder = "Alerts";
              interval = "1m";
              rules = rules.alerts;
            }
          ];
        };
      };
    })
  ];
}

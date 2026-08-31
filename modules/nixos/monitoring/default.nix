# Metrics: node_exporter everywhere, VictoriaMetrics live and history tiers, Grafana on the server.

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

  instanceName = lib.replaceStrings [ "_" ] [ "" ] config.networking.hostName;

  yaml = pkgs.formats.yaml { };
  json = pkgs.formats.json { };

  hiresPort = 9090;
  longtermPort = 9091;
  powerStatePort = 9093;

  vmScrapeConfig = yaml.generate "vm-scrape.yml" {
    global = {
      scrape_interval = "1s";
      scrape_timeout = "900ms";
    };
    scrape_configs = [
      {
        job_name = "power-state";
        honor_labels = true;
        static_configs = [ { targets = [ "127.0.0.1:${toString powerStatePort}" ]; } ];
      }
      {
        job_name = "node";
        metric_relabel_configs = nodeDrops;
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
            labels.instance = instanceName;
          }
        ];
      }
      {
        job_name = "power-meter";
        scrape_interval = "5s";
        static_configs = lib.mapAttrsToList (instance: target: {
          targets = [ target ];
          labels.instance = instance;
        }) cfg.power.meters;
      }
      {
        job_name = "victoriametrics";
        scrape_interval = "15s";
        metric_relabel_configs = bucketDrops;
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString hiresPort}" ];
            labels = {
              instance = instanceName;
              tier = "hires";
            };
          }
          {
            targets = [ "127.0.0.1:${toString longtermPort}" ];
            labels = {
              instance = instanceName;
              tier = "history";
            };
          }
        ];
      }
    ];
  };

  historyDataDir = "/var/lib/victoriametrics-history";

  rollupCopy = pkgs.writeShellApplication {
    name = "vm-rollup-copy";
    runtimeInputs = [
      pkgs.curl
      pkgs.gzip
    ];
    text = ''
      for port in ${toString hiresPort} ${toString longtermPort}; do
        curl --fail --silent --max-time 5 "http://127.0.0.1:$port/health" >/dev/null 2>&1 || exit 0
      done

      curl --fail --silent --show-error --get \
        --data-urlencode 'match[]={__name__=~".*:1h(_max|_min)?"}' \
        --data-urlencode "start=-3h" \
        "http://127.0.0.1:${toString hiresPort}/api/v1/export" \
      | curl --fail --silent --show-error --data-binary @- \
        "http://127.0.0.1:${toString longtermPort}/api/v1/import"
    '';
  };

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
          "http://${config.local.monitoring.telemetry.serverAddress}:${toString powerStatePort}/metrics/job/host_power_state/instance/${instanceName}"
    '';
  };

  alertDurationTracker = pkgs.writeShellApplication {
    name = "track-grafana-alert-durations";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      set -euo pipefail

      state="$STATE_DIRECTORY/active.json"
      previous='{}'
      if [ -s "$state" ] && jq -e . "$state" >/dev/null 2>&1; then
        previous=$(cat "$state")
      fi
      response=$(curl --fail --silent --show-error --get \
        --data-urlencode 'query=GRAFANA_ALERTS{grafana_alertstate=~"pending|alerting|recovering"}' \
        http://127.0.0.1:${toString hiresPort}/api/v1/query)
      active=$(jq -c '
        [ .data.result[]? | .metric
          | with_entries(select(.key as $key | ["alert_uid", "instance", "name", "mountpoint", "peer", "device", "host", "project", "failed_package", "trace_id", "id"] | index($key)))
          | select(.alert_uid != null)
          | { labels: ., key: (to_entries | sort_by(.key) | tojson) }
        ] | unique_by(.key)
      ' <<<"$response")
      now=$(date +%s)
      next=$(jq -c --argjson previous "$previous" --argjson active "$active" --argjson now "$now" '
        reduce $active[] as $alert ({}; .[$alert.key] = ($previous[$alert.key] // ($now | tonumber)))
      ')
      tmp="$state.$$"
      printf '%s\n' "$next" > "$tmp"
      mv "$tmp" "$state"

      {
        echo '# HELP grafana_alert_sustained_since_seconds Unix time when this Grafana alert condition first became pending.'
        echo '# TYPE grafana_alert_sustained_since_seconds gauge'
        jq -r '
          to_entries[]
          | .value as $since
          | (.key | fromjson | to_entries | sort_by(.key)
             | map(.key + "=" + (.value | @json)) | join(",")) as $labels
          | "grafana_alert_sustained_since_seconds{" + $labels + "} " + ($since | tostring)
        ' <<<"$next"
      } | curl --fail --silent --show-error --request PUT --data-binary @- \
        http://127.0.0.1:${toString powerStatePort}/metrics/job/grafana_alert_duration
    '';
  };

  ruleFile = name: groups: yaml.generate "${name}.yml" { inherit groups; };

  nodeDrops = [
    {
      source_labels = [
        "__name__"
        "state"
      ];
      separator = ";";
      regex = "node_systemd_unit_state;(active|activating|deactivating|inactive)";
      action = "drop";
    }
    {
      source_labels = [ "__name__" ];
      regex = "node_cpu_guest_seconds_total|node_cpu_scaling_governor|node_scrape_collector_duration_seconds";
      action = "drop";
    }
  ];

  bucketDrops = [
    {
      source_labels = [ "__name__" ];
      regex = ".*_bucket";
      action = "drop";
    }
  ];

  datasource = name: uid: port: {
    inherit name uid;
    type = "prometheus";
    access = "proxy";
    url = "http://127.0.0.1:${toString port}";
    isDefault = uid == "prometheus-lt";
    jsonData = {
      timeInterval = if port == longtermPort then "1h" else "1s";
      prometheusType = "Prometheus";
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
    ./power-model.nix
    ./smart.nix
    ./telemetry.nix
    ./textfile.nix
  ];

  options.local.monitoring = {
    exporter.enable = lib.mkEnableOption "node_exporter and its textfile collectors";

    exporter.hwmonChipExclude = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Additional regex of hwmon chips node_exporter must not read.";
    };

    exporter.scrapeCadenceOverrides = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            collector = lib.mkOption {
              type = lib.types.enum [ "hwmon" ];
              default = "hwmon";
              description = "Collector whose metrics use the overridden cadence.";
            };
            match = lib.mkOption {
              type = lib.types.str;
              description = "Regex matching node_exporter chip labels assigned to this cadence.";
            };
            interval = lib.mkOption {
              type = lib.types.str;
              description = "Systemd duration between samples.";
            };
            onlyWhenActive = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Sample matched drive sensors only while their disk is active.";
            };
          };
        }
      );
      default = { };
      description = "Named metric-source overrides sampled independently of the main exporter cadence.";
    };

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
      tariffPencePerKwh = lib.mkOption {
        type = lib.types.number;
        default = 25;
        description = "Electricity price used for the cost panels.";
      };
    };

    retention = {
      hires = lib.mkOption {
        type = lib.types.str;
        default = "7d";
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
      driveTempCelsius = lib.mkOption {
        type = lib.types.number;
        default = 50;
        description = "Spinning disk temperature that raises a warning.";
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

      inodeFreeRatio = lib.mkOption {
        type = lib.types.number;
        default = 0.1;
        description = "Free inode fraction below which a filesystem alerts.";
      };

      reallocatedSectors = lib.mkOption {
        type = lib.types.number;
        default = 0;
        description = "Remapped sector count a drive may reach before alerting.";
      };

      smartStaleSeconds = lib.mkOption {
        type = lib.types.number;
        default = 172800;
        description = "Age of the newest SMART read before a drive is treated as unreadable.";
      };

      ssdWearRatio = lib.mkOption {
        type = lib.types.number;
        default = 0.8;
        description = "Fraction of rated write endurance consumed before alerting.";
      };

      thrashScore = lib.mkOption {
        type = lib.types.number;
        default = 0.25;
        description = "Combined major-fault and memory-stall score that counts as thrashing.";
      };

      swapInPagesPerSecond = lib.mkOption {
        type = lib.types.number;
        default = 200;
        description = "Sustained pages read back from swap per second before alerting.";
      };

      diskLatencySeconds = lib.mkOption {
        type = lib.types.number;
        default = 0.5;
        description = "Mean read latency above which a drive alerts.";
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
            pre)
              ${pkgs.coreutils}/bin/timeout 2 \
                ${powerStateReporter}/bin/report-power-state S3 || true
              ;;
            post)
              ${config.systemd.package}/bin/systemctl restart --no-block \
                report-power-state-running.service
              ;;
          esac
        '';
      };

      systemd.services.report-power-state-running = {
        description = "Report that this host is running";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "tailscaled.service"
        ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${powerStateReporter}/bin/report-power-state running";
          Restart = "on-failure";
          RestartSec = "15s";
        };
      };

      powerManagement.powerDownCommands = lib.mkAfter ''
        ${pkgs.coreutils}/bin/timeout 2 \
          ${powerStateReporter}/bin/report-power-state S5 || true
      '';
    })

    (lib.mkIf (cfg.exporter.enable && !cfg.server.enable) {
      systemd.services.vmagent = {
        startLimitIntervalSec = 0;
        serviceConfig = {
          Restart = lib.mkForce "always";
          RestartSec = "30s";
        };
      };

      services.vmagent = {
        enable = true;
        remoteWrite.url = "http://${cfg.telemetry.serverAddress}:${toString hiresPort}/api/v1/write";
        extraArgs = [
          "-remoteWrite.maxDiskUsagePerURL=2GB"
          "-remoteWrite.flushInterval=5s"
        ];
        prometheusConfig = {
          global = {
            scrape_interval = "1s";
            scrape_timeout = "900ms";
          };
          scrape_configs = [
            {
              job_name = "node";
              metric_relabel_configs = nodeDrops;
              static_configs = [
                {
                  targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
                  labels.instance = instanceName;
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
      services.victoriametrics = {
        enable = true;
        listenAddress = "0.0.0.0:${toString hiresPort}";
        retentionPeriod = cfg.retention.hires;
        extraOptions = [
          "-promscrape.config=${vmScrapeConfig}"
          "-search.maxStalenessInterval=2h"
        ];
      };

      systemd.services.victoriametrics-history = {
        description = "VictoriaMetrics history tier";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          ExecStart = lib.concatStringsSep " " [
            "${config.services.victoriametrics.package}/bin/victoria-metrics"
            "-httpListenAddr=127.0.0.1:${toString longtermPort}"
            "-retentionPeriod=100y"
            "-storageDataPath=${historyDataDir}"
          ];
          DynamicUser = true;
          StateDirectory = "victoriametrics-history";
          Restart = "always";
          RestartSec = "10s";
        };
      };

      services.vmalert.instances.main = {
        enable = true;
        settings = {
          "datasource.url" = "http://127.0.0.1:${toString hiresPort}";
          "remoteWrite.url" = "http://127.0.0.1:${toString hiresPort}";
          "remoteRead.url" = "http://127.0.0.1:${toString hiresPort}";
          "notifier.blackhole" = true;
          "evaluationInterval" = "1s";
        };
        rules.groups = rules.hires ++ rules.hourly;
      };

      systemd.services.vm-rollup-copy = {
        description = "Copy 1h rollups into the history tier";
        after = [ "victoriametrics.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe rollupCopy;
        };
      };

      systemd.timers.vm-rollup-copy = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnActiveSec = "1h";
          OnUnitActiveSec = "1h";
          RandomizedDelaySec = "5m";
        };
      };

      services.prometheus.pushgateway = {
        enable = true;
        persistMetrics = true;
        web.listen-address = "0.0.0.0:${toString powerStatePort}";
      };

      networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
        hiresPort
        powerStatePort
      ];

    })

    (lib.mkIf cfg.grafana.enable {
      sops.secrets."grafana-secret-key".owner = "grafana";
      sops.secrets."grafana-admin-password".owner = "grafana";
      systemd.services.grafana = {
        after = [ "sops-install-secrets.service" ];
        wants = [ "sops-install-secrets.service" ];
        environment = {
          GOMEMLIMIT = "144MiB";
          GOGC = "40";
        };
        serviceConfig.MemoryHigh = "224M";
      };

      services.grafana = {
        enable = true;
        declarativePlugins = [
          pkgs.grafanaPlugins.grafana-metricsdrilldown-app
        ];
        settings.server = {
          http_addr = "127.0.0.1";
          http_port = 3000;
        };
        settings.dashboards.default_home_dashboard_path = "${dashboardDir "overview"}/home.json";
        settings.security.secret_key = "$__file{${config.sops.secrets."grafana-secret-key".path}}";
        settings.security.admin_password = "$__file{${config.sops.secrets."grafana-admin-password".path}}";
        settings."unified_alerting.state_history" = {
          enabled = true;
          backend = "annotations";
        };
        settings.feature_toggles.enable = "alertingCentralAlertHistory";
        settings.analytics = {
          reporting_enabled = false;
          check_for_updates = false;
          check_for_plugin_updates = false;
        };
        settings.live.max_connections = 0;
        settings."auth.anonymous".enabled = false;

        provision.datasources.settings = {
          apiVersion = 1;
          deleteDatasources = [
            {
              name = "Loki";
              orgId = 1;
            }
            {
              name = "Tempo";
              orgId = 1;
            }
            {
              name = "Prometheus (1s)";
              orgId = 1;
            }
            {
              name = "Prometheus (1m)";
              orgId = 1;
            }
            {
              name = "Prometheus (1h)";
              orgId = 1;
            }
          ];
          datasources = [
            (datasource "Live (1s, 7d)" "prometheus" hiresPort)
            (datasource "Live (1s, 7d) default" "prometheus-lt" hiresPort)
            (datasource "History (1h, forever)" "prometheus-archive" longtermPort)
          ];
        };

        provision.dashboards.settings = {
          apiVersion = 1;
          providers = [
            (dashboardProvider "overview" "Overview")
            (dashboardProvider "metrics" "Metrics")
            (dashboardProvider "archive" "Archive")
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

      # admin_password only applies when grafana first creates its database, so an existing
      # install keeps the old password and the break-glass path silently does not work.
      systemd.services.grafana-admin-password = {
        description = "Reset the Grafana admin password from sops";
        wantedBy = [ "multi-user.target" ];
        after = [ "grafana.service" ];
        wants = [ "grafana.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "grafana";
          StateDirectory = "grafana";
          WorkingDirectory = "/var/lib/grafana";
          ExecStart = pkgs.writeShellScript "grafana-admin-password" ''
            exec ${config.services.grafana.package}/bin/grafana cli \
              --homepath ${config.services.grafana.package}/share/grafana \
              --configOverrides "cfg:default.paths.data=/var/lib/grafana" \
              admin reset-admin-password "$(cat ${config.sops.secrets."grafana-admin-password".path})"
          '';
        };
      };

      systemd.services.grafana-alert-duration-tracker = {
        description = "Track Grafana alert condition start times";
        after = [
          "grafana.service"
          "pushgateway.service"
        ];
        wants = [ "pushgateway.service" ];
        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
          StateDirectory = "grafana-alert-duration-tracker";
          ExecCondition = "${pkgs.curl}/bin/curl --fail --silent --max-time 5 http://127.0.0.1:${toString hiresPort}/health";
          ExecStart = lib.getExe alertDurationTracker;
        };
      };

      systemd.timers.grafana-alert-duration-tracker = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitActiveSec = "1m";
          AccuracySec = "1s";
        };
      };
    })
  ];
}

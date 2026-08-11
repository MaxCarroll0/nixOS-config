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
    jsonData.timeInterval = if uid == "prometheus" then "1s" else "1m";
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
  imports = [ ./textfile.nix ];

  options.local.monitoring = {
    exporter.enable = lib.mkEnableOption "node_exporter and its textfile collectors";

    server.enable = lib.mkEnableOption "the Prometheus tiers";

    grafana.enable = lib.mkEnableOption "Grafana with the provisioned dashboards";

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
      baselineWatts = lib.mkOption {
        type = lib.types.number;
        default = 25;
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
        listenAddress = "127.0.0.1";
        retentionTime = cfg.retention.hires;
        globalConfig = {
          scrape_interval = "1s";
          scrape_timeout = "900ms";
          evaluation_interval = "15s";
        };
        ruleFiles = [ (ruleFile "hires-rules" rules.hires) ];
        scrapeConfigs = [
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
                targets = [
                  "127.0.0.1:${toString hiresPort}"
                  "127.0.0.1:${toString longtermPort}"
                  "127.0.0.1:${toString archivePort}"
                ];
              }
            ];
          }
        ]
        ++ lib.mapAttrsToList (instance: target: {
          job_name = "node-${instance}";
          static_configs = [
            {
              targets = [ target ];
              labels.instance = instance;
            }
          ];
        }) cfg.targets;
      };

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
        settings.server = {
          http_addr = "0.0.0.0";
          http_port = 3000;
        };
        settings.security.secret_key = "$__file{${config.sops.secrets."grafana-secret-key".path}}";
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
          ];
        };

        provision.dashboards.settings = {
          apiVersion = 1;
          providers = [
            (dashboardProvider "live" "Live")
            (dashboardProvider "history" "History")
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
    })
  ];
}

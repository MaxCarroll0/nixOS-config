# Fleet logs and traces through Alloy, Loki and Tempo.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.monitoring.telemetry;
  host = config.networking.hostName;
  server = if cfg.server.enable then "127.0.0.1" else cfg.serverAddress;
  alloyConfig = pkgs.writeText "alloy-${host}.alloy" ''
    logging {
      level  = "info"
      format = "logfmt"
    }

    loki.relabel "journal" {
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }

      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "level"
      }

      rule {
        source_labels = ["__journal_syslog_identifier"]
        target_label  = "service_name"
      }
    }

    loki.source.journal "system" {
      forward_to    = [loki.secretfilter.redact.receiver]
      relabel_rules = loki.relabel.journal.rules
      labels = {
        host   = "${host}",
        source = "journal",
      }
    }

    loki.secretfilter "redact" {
      forward_to        = [loki.write.central.receiver]
      redact_percent    = 100
      processing_timeout = "250ms"
      drop_on_timeout   = true
    }

    loki.write "central" {
      endpoint {
        url = "http://${server}:3100/loki/api/v1/push"
      }
    }

    otelcol.receiver.otlp "nix" {
      http {
        endpoint = "127.0.0.1:14318"
      }

      output {
        traces = [otelcol.exporter.otlp.tempo.input]
      }
    }

    otelcol.exporter.otlp "tempo" {
      client {
        endpoint = "${server}:4317"

        tls {
          insecure = true
        }
      }
    }
  '';
in

{
  options.local.monitoring.telemetry = {
    collector.enable = lib.mkEnableOption "journal and trace collection";

    server.enable = lib.mkEnableOption "central Loki and Tempo storage";

    serverAddress = lib.mkOption {
      type = lib.types.str;
      default = "100.106.140.88";
      description = "Tailnet address of the telemetry server.";
    };

    journalRetention = lib.mkOption {
      type = lib.types.str;
      default = "720h";
      description = "Retention for journals and failed build logs.";
    };

    traceRetention = lib.mkOption {
      type = lib.types.str;
      default = "2160h";
      description = "Retention for detailed traces.";
    };

    buildSummaryRetention = lib.mkOption {
      type = lib.types.str;
      default = "8760h";
      description = "Retention for compact Nix build summaries.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.collector.enable {
      services.alloy = {
        enable = true;
        configPath = alloyConfig;
        extraFlags = [
          "--server.http.listen-addr=127.0.0.1:12345"
          "--stability.level=experimental"
          "--disable-reporting"
        ];
      };
    })

    (lib.mkIf cfg.server.enable {
      services.loki = {
        enable = true;
        configuration = {
          auth_enabled = false;
          server = {
            http_listen_address = "0.0.0.0";
            http_listen_port = 3100;
            grpc_listen_port = 9096;
          };
          common = {
            path_prefix = "/var/lib/loki";
            replication_factor = 1;
            ring.kvstore.store = "inmemory";
          };
          schema_config.configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
          storage_config.filesystem.directory = "/var/lib/loki/chunks";
          compactor = {
            working_directory = "/var/lib/loki/compactor";
            retention_enabled = true;
            delete_request_store = "filesystem";
          };
          limits_config = {
            retention_period = cfg.journalRetention;
            allow_structured_metadata = true;
            split_queries_by_interval = "24h";
            max_query_parallelism = 32;
            retention_stream = [
              {
                selector = ''{service_name="nix-observer-summary"}'';
                priority = 1;
                period = cfg.buildSummaryRetention;
              }
            ];
          };
        };
      };

      services.tempo = {
        enable = true;
        settings = {
          server = {
            http_listen_address = "127.0.0.1";
            http_listen_port = 3200;
          };
          distributor.receivers.otlp.protocols.grpc.endpoint = "0.0.0.0:4317";
          storage.trace = {
            backend = "local";
            local.path = "/var/lib/tempo/traces";
            wal.path = "/var/lib/tempo/wal";
          };
          compactor.compaction.block_retention = cfg.traceRetention;
          usage_report.reporting_enabled = false;
        };
      };

      networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
        3100
        4317
      ];
    })
  ];
}

# Textfile collectors feeding node_exporter: sensor names, tailnet peers, wireguard.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.monitoring;

  textfileDir = "/var/lib/node-exporter-textfile";

  sensorNameTable = pkgs.writeText "sensor-names" (
    lib.concatStringsSep "\n" (lib.mapAttrsToList (key: name: "${key}\t${name}") cfg.sensorNames)
  );

  writeCollector =
    name: runtimeInputs: text:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.coreutils ] ++ runtimeInputs;
      text = ''
        out=${textfileDir}/${name}.prom
        tmp=$out.$$
        trap 'rm -f "$tmp"' EXIT
        {
        ${text}
        } > "$tmp"
        chmod 0644 "$tmp"
        mv "$tmp" "$out"
      '';
    };

  sensorNames = writeCollector "sensor-names" [ pkgs.gnused ] ''
    echo '# HELP node_sensor_name Friendly name for a hwmon sensor, keyed by chip name and sensor.'
    echo '# TYPE node_sensor_name gauge'
    for chip in /sys/class/hwmon/hwmon*; do
      chip_name=$(cat "$chip/name" 2>/dev/null) || continue
      for input in "$chip"/*_input; do
        [ -e "$input" ] || continue
        sensor=$(basename "$input" _input)
        name=$(sed -n "s|^$chip_name:$sensor\t||p" ${sensorNameTable} | head -1)
        if [ -z "$name" ] && [ -r "$chip/''${sensor}_label" ]; then
          name=$(cat "$chip/''${sensor}_label")
        fi
        [ -n "$name" ] || name="$chip_name $sensor"
        name=''${name//\\/}
        name=''${name//\"/}
        printf 'node_sensor_name{chip_name="%s",sensor="%s",name="%s"} 1\n' \
          "$chip_name" "$sensor" "$name"
      done
    done

    echo '# HELP pc_power_baseline_watts Modelled draw of parts with no telemetry.'
    echo '# TYPE pc_power_baseline_watts gauge'
    echo 'pc_power_baseline_watts ${toString cfg.totalPower.baselineWatts}'
    echo '# HELP pc_power_psu_efficiency Assumed PSU conversion efficiency.'
    echo '# TYPE pc_power_psu_efficiency gauge'
    echo 'pc_power_psu_efficiency ${toString cfg.totalPower.psuEfficiency}'
    echo '# HELP pc_power_tariff_gbp_per_kwh Electricity price used for cost panels.'
    echo '# TYPE pc_power_tariff_gbp_per_kwh gauge'
    echo 'pc_power_tariff_gbp_per_kwh ${toString (cfg.totalPower.tariffPencePerKwh / 100.0)}'
  '';

  tailscaleMetrics =
    writeCollector "tailscale"
      [
        pkgs.tailscale
        pkgs.jq
      ]
      ''
        status=$(tailscale status --json) || exit 0

        echo '# HELP tailscale_peer_rx_bytes_total Bytes received from a peer this session.'
        echo '# TYPE tailscale_peer_rx_bytes_total counter'
        echo '# HELP tailscale_peer_tx_bytes_total Bytes sent to a peer this session.'
        echo '# TYPE tailscale_peer_tx_bytes_total counter'
        echo '# HELP tailscale_peer_online Whether the coordination server reports the peer as up.'
        echo '# TYPE tailscale_peer_online gauge'
        echo '# HELP tailscale_peer_direct Whether traffic to the peer avoids a DERP relay.'
        echo '# TYPE tailscale_peer_direct gauge'
        echo '# HELP tailscale_peer_last_handshake_seconds Unix time of the last wireguard handshake.'
        echo '# TYPE tailscale_peer_last_handshake_seconds gauge'

        jq -r '.Peer[] | [.HostName, .OS, .Relay, (.Online|tostring),
                          (if .CurAddr == "" then "0" else "1" end),
                          (.RxBytes|tostring), (.TxBytes|tostring),
                          (.LastHandshake // "")] | @tsv' <<<"$status" \
        | while IFS=$'\t' read -r peer os relay online direct rx tx handshake; do
            labels="peer=\"$peer\",peer_os=\"$os\",relay=\"$relay\""
            printf 'tailscale_peer_rx_bytes_total{%s} %s\n' "$labels" "$rx"
            printf 'tailscale_peer_tx_bytes_total{%s} %s\n' "$labels" "$tx"
            printf 'tailscale_peer_online{%s} %s\n' "$labels" "$([ "$online" = true ] && echo 1 || echo 0)"
            printf 'tailscale_peer_direct{%s} %s\n' "$labels" "$direct"
            epoch=0
            case "$handshake" in
              ""|0001-01-01*) ;;
              *) epoch=$(date -d "$handshake" +%s 2>/dev/null || echo 0) ;;
            esac
            printf 'tailscale_peer_last_handshake_seconds{%s} %s\n' "$labels" "$epoch"
          done

        tailscale metrics print 2>/dev/null || true
      '';

  wireguardMetrics =
    writeCollector "wireguard"
      [
        pkgs.wireguard-tools
        pkgs.gawk
      ]
      ''
        echo '# HELP wireguard_peer_latest_handshake_seconds Unix time of the last handshake.'
        echo '# TYPE wireguard_peer_latest_handshake_seconds gauge'
        echo '# HELP wireguard_peer_rx_bytes_total Bytes received from the peer.'
        echo '# TYPE wireguard_peer_rx_bytes_total counter'
        echo '# HELP wireguard_peer_tx_bytes_total Bytes sent to the peer.'
        echo '# TYPE wireguard_peer_tx_bytes_total counter'

        wg show all dump 2>/dev/null | awk -F'\t' 'NF >= 9 {
          split($4, endpoint, ":")
          labels = "interface=\"" $1 "\",endpoint=\"" endpoint[1] "\""
          printf "wireguard_peer_latest_handshake_seconds{%s} %s\n", labels, $6
          printf "wireguard_peer_rx_bytes_total{%s} %s\n", labels, $7
          printf "wireguard_peer_tx_bytes_total{%s} %s\n", labels, $8
        }'
      '';

  collectorService = collector: {
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe collector;
    };
  };

  hasWireguard = config.networking.wg-quick.interfaces != { };

  collectorTimer = interval: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = interval;
      AccuracySec = "1s";
    };
  };
in

{
  config = lib.mkIf cfg.exporter.enable {
    systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];

    services.prometheus.exporters.node.extraFlags = [
      "--collector.textfile.directory=${textfileDir}"
    ];

    systemd.services.textfile-sensor-names = lib.mkMerge [
      (collectorService sensorNames)
      {
        description = "Publish friendly hwmon sensor names";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-modules-load.service" ];
        restartTriggers = [
          sensorNameTable
          (toString cfg.totalPower.baselineWatts)
        ];
      }
    ];

    systemd.services.textfile-tailscale = lib.mkIf config.services.tailscale.enable (
      lib.mkMerge [
        (collectorService tailscaleMetrics)
        { description = "Publish per-peer tailnet traffic and reachability"; }
      ]
    );

    systemd.timers.textfile-tailscale = lib.mkIf config.services.tailscale.enable (
      collectorTimer "15s"
    );

    systemd.services.textfile-wireguard = lib.mkIf hasWireguard (
      lib.mkMerge [
        (collectorService wireguardMetrics)
        { description = "Publish wireguard handshake age and byte counters"; }
      ]
    );

    systemd.timers.textfile-wireguard = lib.mkIf hasWireguard (collectorTimer "30s");
  };
}

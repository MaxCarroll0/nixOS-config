# Shared plumbing for the node_exporter textfile collectors.

{ pkgs, lib }:

rec {
  textfileDir = "/var/lib/node-exporter-textfile";

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

  collectorService = collector: {
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe collector;
    };
  };

  collectorTimer = interval: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = interval;
      AccuracySec = "1s";
    };
  };
}

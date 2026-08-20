# Records boots that followed an unclean shutdown, which a hard reset cannot log for itself.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.uncleanBoot;
  state = "/var/lib/unclean-boot";
  marker = "${state}/clean";

  record = pkgs.writeShellApplication {
    name = "unclean-boot-record";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
      pkgs.gawk
    ];
    text = ''
      count=$(cat ${state}/count 2>/dev/null || echo 0)
      last=$(cat ${state}/last 2>/dev/null || echo 0)
      boot=$(date +%s)

      if [ -e ${marker} ]; then
        was=0
        rm -f ${marker}
      else
        was=1
        count=$((count + 1))
        last=$boot
        logger -t unclean-boot -p daemon.warning \
          "previous shutdown was unclean; this is unclean boot number $count"
      fi

      printf '%s' "$count" > ${state}/count
      printf '%s' "$last" > ${state}/last

      tmp=${cfg.metricsFile}.tmp
      {
        echo '# HELP node_boot_unclean_total Boots that followed a shutdown with no clean marker.'
        echo '# TYPE node_boot_unclean_total counter'
        echo "node_boot_unclean_total $count"
        echo '# HELP node_boot_was_unclean Whether the current boot followed an unclean shutdown.'
        echo '# TYPE node_boot_was_unclean gauge'
        echo "node_boot_was_unclean $was"
        echo '# HELP node_boot_last_unclean_timestamp_seconds When the most recent unclean boot happened.'
        echo '# TYPE node_boot_last_unclean_timestamp_seconds gauge'
        echo "node_boot_last_unclean_timestamp_seconds $last"
      } > "$tmp"
      mv "$tmp" ${cfg.metricsFile}
    '';
  };

  mark = pkgs.writeShellApplication {
    name = "unclean-boot-mark";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      : > ${marker}
      sync ${marker} 2>/dev/null || sync
    '';
  };
in

{
  options.local.uncleanBoot = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Count boots that followed a hard reset or power loss.";
    };

    metricsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter-textfile/unclean-boot.prom";
      description = "Textfile collector output for unclean boot counts.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d ${state} 0755 root root - -" ];

    systemd.services.unclean-boot = {
      description = "Record whether the previous shutdown was clean";
      wantedBy = [ "multi-user.target" ];
      before = [ "shutdown.target" ];
      conflicts = [ "shutdown.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe record;
        ExecStop = lib.getExe mark;
      };
    };
  };
}

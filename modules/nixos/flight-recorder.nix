# Durable ring of the last few minutes of vitals, fsynced so a hard reset cannot lose them.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.flightRecorder;
  current = "${cfg.directory}/current.csv";
  previous = "${cfg.directory}/previous.csv";

  fieldReads = lib.concatMapStringsSep "\n" (f: ''
    ${f.name}=$(awk -v m='${f.match}' '$0 ~ m { print $NF; exit }' ${f.file} 2>/dev/null || true)
  '') cfg.fields;

  fieldNames = lib.concatMapStringsSep "," (f: f.name) cfg.fields;
  fieldValues = lib.concatMapStringsSep "," (f: "\${${f.name}:-}") cfg.fields;

  record = pkgs.writeShellApplication {
    name = "flight-recorder";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      header='epoch,load1,mem_available_kb,procs_running,procs_blocked${lib.optionalString (cfg.fields != [ ]) ",${fieldNames}"}'
      lines=0

      if [ ! -s ${current} ]; then
        printf '%s\n' "$header" > ${current}
      fi

      while true; do
        read -r load1 _ < /proc/loadavg
        memavail=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
        running=$(awk '/^procs_running/ { print $2; exit }' /proc/stat)
        blocked=$(awk '/^procs_blocked/ { print $2; exit }' /proc/stat)
        ${fieldReads}

        printf '%s,%s,%s,%s,%s${lib.optionalString (cfg.fields != [ ]) ",%s"}\n' \
          "$(date +%s)" "$load1" "$memavail" "$running" "$blocked" \
          ${lib.optionalString (cfg.fields != [ ]) "\"${fieldValues}\""} >> ${current}

        sync -d ${current} 2>/dev/null || true

        lines=$((lines + 1))
        if [ "$lines" -ge ${toString cfg.maxSamples} ]; then
          mv ${current} ${previous}
          printf '%s\n' "$header" > ${current}
          sync -d ${current} 2>/dev/null || true
          lines=0
        fi

        sleep ${toString cfg.intervalSeconds}
      done
    '';
  };

  rotate = pkgs.writeShellApplication {
    name = "flight-recorder-rotate";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      if [ -s ${current} ]; then
        mv ${current} ${previous}
        logger -t flight-recorder -p daemon.warning \
          "final ${toString cfg.dumpSamples} samples before the previous shutdown:"
        tail -n ${toString cfg.dumpSamples} ${previous} \
          | while IFS= read -r line; do
              logger -t flight-recorder -p daemon.warning "  $line"
            done
      fi
    '';
  };
in

{
  options.local.flightRecorder = {
    enable = lib.mkEnableOption "a durable ring buffer of system vitals";

    directory = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/flight-recorder";
      description = "Where the ring buffer files live.";
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Seconds between samples.";
    };

    maxSamples = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "Samples per ring file before rotating; two files are kept.";
    };

    dumpSamples = lib.mkOption {
      type = lib.types.ints.positive;
      default = 25;
      description = "Samples from before the last shutdown written to the journal at boot.";
    };

    fields = lib.mkOption {
      default = [ ];
      description = "Extra values scraped out of textfile-collector output each sample.";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Column name.";
            };
            file = lib.mkOption {
              type = lib.types.str;
              description = "File to read the value from.";
            };
            match = lib.mkOption {
              type = lib.types.str;
              description = "awk match expression selecting the line; the last field is taken.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d ${cfg.directory} 0755 root root - -" ];

    systemd.services.flight-recorder = {
      description = "Record system vitals durably for post-mortem after a hard reset";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStartPre = "+${lib.getExe rotate}";
        ExecStart = lib.getExe record;
        Restart = "always";
        RestartSec = 5;
        Nice = 19;
        IOSchedulingClass = "idle";
        MemoryMax = "32M";
      };
    };
  };
}

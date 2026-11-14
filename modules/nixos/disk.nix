# Disk pressure, tiered store retention, scratch sweeping and the disk ledger.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.disk;
  pressure = cfg.pressure;
  home = "/home/${cfg.user}";
  uid = toString cfg.uid;
  gib = 1024 * 1024 * 1024;

  retention = pkgs.writeShellApplication {
    name = "project-closure-retention";
    runtimeInputs = [
      config.nix.package
      pkgs.angrr
      pkgs.python3
    ];
    text = ''
      exec python3 ${./project-closure-retention.py} "$@"
    '';
  };

  collect = pkgs.writeShellApplication {
    name = "store-collect";
    runtimeInputs = [
      config.nix.package
      pkgs.python3
    ];
    text = ''
      exec python3 ${./store-collect.py} "$@"
    '';
  };

  scratchClean = pkgs.writeShellApplication {
    name = "project-scratch-clean";
    runtimeInputs = [
      pkgs.git
      pkgs.python3
    ];
    text = ''
      export SCRATCH_OFFLOAD_DIR=${if cfg.offload.enable then "${home}/offload" else ""}
      export SCRATCH_MIN_FREE_BYTES=${toString (pressure.minFreeGiB * gib)}
      exec python3 ${./project-scratch-clean.py} "$@"
    '';
  };

  stateDir = "/var/lib/disk-ledger";

  ledger = pkgs.writeShellApplication {
    name = "disk-ledger";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.python3
      pkgs.util-linux
    ];
    text = ''
      export RETENTION_MODULE=${./project-closure-retention.py}
      export COLLECT_MODULE=${./store-collect.py}
      export LEDGER_HOME=${home}
      export LEDGER_USER=${cfg.user}
      export LEDGER_TARGET_BYTES=${toString (pressure.minFreeGiB * gib)}
      export LEDGER_MAX_FREED_BYTES=${toString (pressure.maxFreedGiB * gib)}
      export LEDGER_RUNTIME_DIR=/run/user/${uid}
      export LEDGER_STATE_DIR=${stateDir}
      export LEDGER_UID=${uid}
      export LEDGER_TEXTFILE=/var/lib/node-exporter-textfile/disk-ledger.prom
      export LEDGER_OFFLOAD_DIR=${if cfg.offload.enable then "${home}/offload" else ""}
      export LEDGER_SCRATCH_PLAN="${lib.getExe scratchClean} --home ${home} --state ${home}/.local/state/dev-build"
      exec python3 ${./disk-ledger.py}
    '';
  };

  freeGiB = "df --output=avail -B1G /nix/store | tail -n1";

  resourceLimits = {
    CPUWeight = "idle";
    IOWeight = 10;
    MemoryHigh = "1.5G";
  };
in

{
  options.local.disk = {
    user = lib.mkOption {
      type = lib.types.str;
      default = "max";
      description = "User whose home, caches and runtime directory the disk units manage.";
    };

    offload.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.networking.hostName == "desktopnew";
      description = "Whether ~/offload build trees are in the ledger and reclaimed under pressure.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "Numeric uid of local.disk.user, whose runtime directory receives the ledger.";
    };

    retention = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = retention;
      description = "The project-closure-retention command used by nightly and pressure runs.";
    };

    pressure = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.networking.hostName == "laptop";
        description = "Whether free space below the target triggers retention and bounded collection.";
      };

      minFreeGiB = lib.mkOption {
        type = lib.types.int;
        default = if config.networking.hostName == "desktopnew" then 40 else 20;
        description = "Free space in GiB on /nix/store below which pressure reclaim runs.";
      };

      maxFreedGiB = lib.mkOption {
        type = lib.types.int;
        default = 40;
        description = "Upper bound in GiB on what one pressure run may free.";
      };
    };
  };

  config = {
    environment.systemPackages = [
      collect
      scratchClean
    ];

    systemd.tmpfiles.rules = [ "d ${stateDir} 0755 root root -" ];

    systemd.services.generation-expire = {
      description = "Keep the last 10 generations of every profile";
      path = [ config.nix.package ];
      serviceConfig = resourceLimits // {
        Type = "oneshot";
      };
      script = ''
        for profile in /nix/var/nix/profiles/system /nix/var/nix/profiles/default \
            /nix/var/nix/profiles/per-user/*/* ${home}/.local/state/nix/profiles/*; do
          case "$profile" in *-link) continue ;; esac
          [ -L "$profile" ] || continue
          nix-env --profile "$profile" --delete-generations +10
        done
      '';
    };

    systemd.timers.generation-expire = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };

    systemd.services.disk-pressure = lib.mkIf pressure.enable {
      description = "Reclaim store space when free space is below target";
      path = [
        config.nix.package
        pkgs.coreutils
      ];
      serviceConfig = resourceLimits // {
        Type = "oneshot";
      };
      script = ''
        reclaim() {
          local free need started status result
          free=$(${freeGiB})
          [ "$free" -lt ${toString pressure.minFreeGiB} ] || return 0
          need=$(( ${toString pressure.minFreeGiB} - free + 5 ))
          [ "$need" -le ${toString pressure.maxFreedGiB} ] || need=${toString pressure.maxFreedGiB}
          started=$(date +%s)
          status=0
          result=$("$@" "$need") || status=$?
          ${pkgs.jq}/bin/jq -c --argjson at "$started" --argjson status "$status" --argjson free "$free" --argjson need "$need" \
            '{at: $at, stage: (.stage // "unknown"), status: $status, free_gib: $free, need_gib: $need,
              freed: (.freed // 0), items: ((.selected // []) | length), seconds: (.seconds // 0)}' \
            <<<"''${result:-{\}}" >> ${stateDir}/events.jsonl
          echo "$result" | ${pkgs.jq}/bin/jq -r '"\(.stage): freed \(.freed / 1073741824 * 10 | round / 10) GiB in \(.selected | length) items, \(.seconds)s"' 2>/dev/null || true
        }
        reclaim ${pkgs.util-linux}/bin/runuser -u ${cfg.user} -- ${lib.getExe scratchClean} \
          --apply --json --home ${home} --state ${home}/.local/state/dev-build --need-gib
        reclaim ${cfg.retention}/bin/project-closure-retention --apply --json --max-freed-gib ${toString pressure.maxFreedGiB} --need-gib
        reclaim ${lib.getExe collect} --apply --json --need-gib
      '';
    };

    systemd.timers.disk-pressure = lib.mkIf pressure.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "15min";
      };
    };

    systemd.paths.disk-pressure = lib.mkIf pressure.enable {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = [
          "${home}/Videos"
          "${home}/Downloads"
        ];
        Unit = "disk-pressure.service";
      };
    };

    systemd.services.disk-ledger = {
      description = "Write the disk ledger for the performance tab and metrics";
      serviceConfig = resourceLimits // {
        Type = "oneshot";
        ExecStart = lib.getExe ledger;
      };
    };

    systemd.timers.disk-ledger = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "15min";
      };
    };

    systemd.user.services.project-scratch-clean = {
      description = "Report reclaimable build outputs, shell temp dirs and caches";
      serviceConfig = resourceLimits // {
        Type = "oneshot";
        ExecStart = lib.getExe scratchClean;
      };
    };

    systemd.user.timers.project-scratch-clean = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
      };
    };
  };
}

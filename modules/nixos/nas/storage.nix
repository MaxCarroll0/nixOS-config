# NAS storage: mergerfs pool over per-disk btrfs, SnapRAID parity, snapshot and sync timers.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas;
  scfg = cfg.storage;

  dataMounts = lib.mapAttrsToList (name: _: "${scfg.diskRoot}/${name}") scfg.dataDisks;

  snapraidConf = pkgs.writeText "snapraid.conf" (
    lib.concatStringsSep "\n" (
      [ "parity ${scfg.parityMount}/snapraid.parity" ]
      ++ lib.mapAttrsToList (name: _: "content ${scfg.diskRoot}/${name}/.snapraid.content") scfg.dataDisks
      ++ [ "content ${scfg.contentDir}/snapraid.content" ]
      ++ lib.mapAttrsToList (name: _: "data ${name} ${scfg.diskRoot}/${name}") scfg.dataDisks
      ++ [
        "exclude *.unrecoverable"
        "exclude /tmp/"
        "exclude .recycle/"
        "exclude .snapshots/"
        "exclude lost+found/"
        "blocksize 256"
        "autosave 250"
      ]
    )
  );

  sync = pkgs.writeShellApplication {
    name = "nas-snapraid-sync";
    runtimeInputs = [
      pkgs.snapraid
      pkgs.util-linux
    ];
    text = ''
      for m in ${lib.escapeShellArgs dataMounts} ${scfg.parityMount}; do
        mountpoint -q "$m" || exit 0
      done
      snapraid --conf ${snapraidConf} touch
      snapraid --conf ${snapraidConf} sync
    '';
  };

  scrub = pkgs.writeShellApplication {
    name = "nas-snapraid-scrub";
    runtimeInputs = [
      pkgs.snapraid
      pkgs.util-linux
    ];
    text = ''
      mountpoint -q ${scfg.parityMount} || exit 0
      snapraid --conf ${snapraidConf} scrub -p ${toString scfg.scrubPercent} -o ${toString scfg.scrubOlderThan}
    '';
  };
in

{
  options.local.nas.storage = {
    enable = lib.mkEnableOption "the mergerfs pool, SnapRAID parity and their timers";

    diskRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/disks";
      description = "Parent of the individual data disk mountpoints.";
    };

    parityMount = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/parity";
      description = "Mountpoint of the parity disk.";
    };

    parityFsType = lib.mkOption {
      type = lib.types.enum [
        "xfs"
        "ext4"
        "btrfs"
      ];
      default = "xfs";
      description = "Filesystem under the parity file. Not copy-on-write: parity is one huge file rewritten in place.";
    };

    contentDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/snapraid";
      description = "Location of the extra SnapRAID content copy held off the array.";
    };

    dataDisks = lib.mkOption {
      default = { };
      description = "Data disks in the pool, keyed by mountpoint name.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.device = lib.mkOption {
            type = lib.types.str;
            description = "Backing device or its /dev/disk/by-uuid path.";
          };

          options.fsType = lib.mkOption {
            type = lib.types.enum [
              "btrfs"
              "nilfs2"
            ];
            default = "btrfs";
            description = "Filesystem on this branch. Branches may differ while a migration is in flight.";
          };
        }
      );
    };

    minFreeSpace = lib.mkOption {
      type = lib.types.str;
      default = "20G";
      description = "Space below which mergerfs stops choosing a branch for new files.";
    };

    scrubPercent = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 8;
      description = "Share of the array scrubbed per run.";
    };

    scrubOlderThan = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Only scrub blocks older than this many days.";
    };
  };

  config = lib.mkIf (cfg.enable && scfg.enable) {
    assertions = [
      {
        assertion = scfg.dataDisks != { };
        message = "local.nas.storage: at least one data disk is required.";
      }
    ];

    nixpkgs.overlays = [
      (_: prev: {
        nilfs-utils = prev.nilfs-utils.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ../../patches/nilfs-utils-chcp-device-arg.patch ];
        });
      })
    ];

    environment.systemPackages = [
      pkgs.snapraid
      pkgs.mergerfs
      pkgs.nilfs-utils
      pkgs.btrfs-progs
      pkgs.xfsprogs
    ];

    fileSystems = lib.mkMerge [
      (lib.mapAttrs' (
        name: d:
        lib.nameValuePair "${scfg.diskRoot}/${name}" {
          device = "/dev/mapper/nas-${name}";
          inherit (d) fsType;
          options = [
            "noauto"
            "noatime"
          ]
          ++ lib.optional (d.fsType == "btrfs") "compress=zstd:1";
        }
      ) scfg.dataDisks)

      {
        ${scfg.parityMount} = {
          device = "/dev/mapper/nas-parity";
          fsType = scfg.parityFsType;
          options = [
            "noauto"
            "noatime"
          ];
        };

        ${cfg.dataRoot} = {
          fsType = "fuse.mergerfs";
          device = lib.concatStringsSep ":" dataMounts;
          options = [
            "cache.files=partial"
            "category.create=eppfrd"
            "func.mkdir=mspmfs"
            "category.search=ff"
            "dropcacheonclose=true"
            "inodecalc=hybrid-hash"
            "minfreespace=${scfg.minFreeSpace}"
            "moveonenospc=pfrd"
            "fsname=nas"
            "nonempty"
            "allow_other"
            "use_ino"
            "noauto"
          ];
        };
      }
    ];

    systemd.tmpfiles.rules = [ "d ${scfg.contentDir} 0700 root root - -" ];

    systemd.units."srv-nas.mount" = {
      overrideStrategy = "asDropin";
      text = ''
        [Unit]
        DefaultDependencies=no
      '';
    };

    systemd.services.nas-snapraid-sync = {
      description = "SnapRAID parity sync";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe sync;
        Nice = 15;
        IOSchedulingClass = "idle";
      };
    };

    systemd.services.nas-snapraid-scrub = {
      description = "SnapRAID scrub";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe scrub;
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.nas-snapraid-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:00:00";
        Persistent = true;
        RandomizedDelaySec = "20m";
      };
    };

    systemd.timers.nas-snapraid-scrub = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun *-*-* 05:30:00";
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };
  };
}

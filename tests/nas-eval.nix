# VM evaluation on dm-crypt over dm-delay, by fill level: the NILFS2 history system, or stock NILFS2 with nilfs_cleanerd defaults.

{
  pkgs,
  lib,
  variant ? "history",
}:

pkgs.testers.runNixOSTest {
  name = if variant == "stock" then "nas-eval-stock" else "nas-eval";
  node.pkgsReadOnly = false;
  nodes.machine =
    { pkgs, ... }:
    let
      state = "/var/lib/nas-checkpoints";
      churn = pkgs.writeShellApplication {
        name = "tmp-churn";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gawk
        ];
        text = ''
          count=$1 mb=$2 rate=$3 log=$4
          mkdir -p /mnt/disks/disk1/tmp
          : > "$log"
          for i in $(seq 0 $((count - 1))); do
            f=/mnt/disks/disk1/tmp/f$((i % 4))
            rm -f "$f"
            t0=$(date +%s.%N)
            if dd if=/dev/zero of="$f" bs=1M count="$mb" conv=fsync status=none 2>/dev/null; then ok=1; else ok=0; fi
            t1=$(date +%s.%N)
            echo "$i $ok $t0 $t1 $(df -B1M --output=avail /mnt/disks/disk1 | tail -1)" >> "$log"
            if [ "$ok" = 0 ]; then
              sleep 1
            elif [ "$rate" -gt 0 ]; then
              sleep "$(awk -v a="$t0" -v b="$t1" -v mb="$mb" -v r="$rate" 'BEGIN { p = mb / r - (b - a); print (p > 0 ? p : 0) }')"
            fi
          done
        '';
      };
      at = pkgs.writeShellApplication {
        name = "nas-at";
        text = ''exec ${lib.getExe pkgs.nas-at} --branch /mnt/disks/disk1 --index ${state}/index.db --pool /mnt/disks/disk1 --view /srv/nas-at --metrics ${state}/nas.prom --suspend /run/nas-promote-suspended --gap-default 5 --reclaim-free "''${NAS_RECLAIM_FREE:-0.15}" "$@"'';
      };
    in
    {
      nixpkgs.overlays = [ (import ../modules/nixos/nas/nilfs-utils.nix { inherit lib; }) ];
      boot.supportedFilesystems = [ "nilfs2" ];
      boot.kernelModules = [
        "dm_crypt"
        "dm_delay"
      ];
      virtualisation.emptyDiskImages = [
        3072
        6144
      ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      programs.fuse.userAllowOther = true;
      environment.systemPackages = [
        at
        churn
        pkgs.nilfs-utils
        pkgs.nilfs-reclaim
        pkgs.sqlite
        pkgs.fio
        pkgs.cryptsetup
        pkgs.lvm2
        pkgs.samba
        pkgs.mergerfs
        pkgs.snapraid
        pkgs.e2fsprogs
      ];
      services.samba = {
        enable = true;
        settings = {
          global = {
            "map to guest" = "Bad User";
            "server min protocol" = "SMB2";
          };
          disk1 = {
            path = "/mnt/disks/disk1";
            "guest ok" = "yes";
            "read only" = "yes";
            "vfs objects" = "shadow_copy2";
            "shadow:mountpoint" = "/mnt/disks/disk1";
            "shadow:snapdir" = "/srv/nas-at";
            "shadow:format" = "@GMT-%Y.%m.%d-%H.%M.%S";
            "shadow:localtime" = "no";
            "shadow:sort" = "desc";
          };
        };
      };
      environment.etc."nilfs_cleanerd.conf".source = "${pkgs.nilfs-utils}/etc/nilfs_cleanerd.conf";
      environment.etc."snapraid.conf".text = ''
        parity /parity/snapraid.parity
        content /parity/snapraid.content
        content /var/lib/snapraid.content
        data d1 /mnt/disks/disk1/
        exclude /.cache/
        exclude /tmp/
      '';
      systemd.tmpfiles.rules = [ "d ${state}/events 0750 root root - -" ];
      systemd.services.nas-history-watch-disk1.serviceConfig = {
        ExecStartPre = "${pkgs.coreutils}/bin/rm -f ${state}/events/disk1.jsonl";
        ExecStart = "${pkgs.fatrace}/bin/fatrace -c -j -f W+D<> -t -t -o ${state}/events/disk1.jsonl";
        WorkingDirectory = "/mnt/disks/disk1";
      };
      systemd.services.nas-at-view.serviceConfig.ExecStart = "${lib.getExe at} serve";
    };
  testScript =
    builtins.readFile ./nas-eval-lib.py
    + builtins.readFile (if variant == "stock" then ./nas-eval-stock.py else ./nas-eval.py);
}

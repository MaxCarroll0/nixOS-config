# VM evaluation: NILFS2 history pass and reclaim under fio, on dm-crypt over dm-delay, by fill level.

{ pkgs, lib }:

pkgs.testers.runNixOSTest {
  name = "nas-eval";
  node.pkgsReadOnly = false;
  nodes.machine =
    { pkgs, ... }:
    let
      state = "/var/lib/nas-checkpoints";
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
      virtualisation.emptyDiskImages = [ 3072 ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      programs.fuse.userAllowOther = true;
      environment.systemPackages = [
        at
        pkgs.nilfs-utils
        pkgs.nilfs-reclaim
        pkgs.sqlite
        pkgs.fio
        pkgs.cryptsetup
        pkgs.lvm2
      ];
      systemd.tmpfiles.rules = [ "d ${state}/events 0750 root root - -" ];
      systemd.services.nas-history-watch-disk1.serviceConfig = {
        ExecStartPre = "${pkgs.coreutils}/bin/rm -f ${state}/events/disk1.jsonl";
        ExecStart = "${pkgs.fatrace}/bin/fatrace -c -j -f W+D<> -t -t -o ${state}/events/disk1.jsonl";
        WorkingDirectory = "/mnt/disks/disk1";
      };
      systemd.services.nas-at-view.serviceConfig.ExecStart = "${lib.getExe at} serve";
    };
  testScript = builtins.readFile ./nas-eval.py;
}

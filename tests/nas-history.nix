# Phase 0 VM test: per-inode drop ranges in libnilfsgc against a real NILFS2 kernel.

{ pkgs, lib }:

pkgs.testers.runNixOSTest {
  name = "nas-history";
  node.pkgsReadOnly = false;
  nodes.machine =
    { pkgs, ... }:
    {
      nixpkgs.overlays = [ (import ../modules/nixos/nas/nilfs-utils.nix { inherit lib; }) ];
      boot.supportedFilesystems = [ "nilfs2" ];
      virtualisation.emptyDiskImages = [ 1024 ];
      virtualisation.memorySize = 1024;
      environment.systemPackages = [
        pkgs.nilfs-utils
        pkgs.nilfs-reclaim
      ];
    };
  testScript = builtins.readFile ./nas-history.py;
}

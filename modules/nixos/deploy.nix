# Deploy tooling: rebuild (snapshot deploys with deploy-rs), deploy-status, activate-detached.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  flakePath = "/home/max/.config/nix";
  facts = import ../../hosts/facts.nix;
  nodes = lib.attrNames (lib.filterAttrs (_: f: f ? tailscale && f ? systems) facts);
  wakePeers = lib.attrNames (config.local.wake.peers or { });

  runtimeEnv = {
    REBUILD_HOST = config.networking.hostName;
    REBUILD_FLAKE = flakePath;
    REBUILD_NODES = lib.concatStringsSep " " nodes;
    REBUILD_WAKE_PEERS = lib.concatStringsSep " " wakePeers;
  };

  rebuild = pkgs.writeShellApplication {
    name = "rebuild";
    inherit runtimeEnv;
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
      pkgs.getent
      pkgs.util-linux
      pkgs.openssh
      pkgs.gawk
    ];
    text = builtins.readFile ./deploy/rebuild.sh;
  };

  deployStatus = pkgs.writeShellApplication {
    name = "deploy-status";
    inherit runtimeEnv;
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
      pkgs.openssh
      pkgs.jq
      config.services.tailscale.package
    ];
    text = builtins.readFile ./deploy/deploy-status.sh;
  };

  activateDetached = pkgs.writeShellApplication {
    name = "activate-detached";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      user="''${1:?deploy-rs passes the activation user as the first argument}"
      shift

      unit="deploy-activate-$$-$(date +%s)"

      journalctl --unit "$unit" --follow --output cat --no-pager --since "-1 min" &
      follower=$!
      trap 'kill "$follower" 2>/dev/null || true' EXIT

      # A transient unit outlives the ssh session it was started from, so a
      # tailscaled restart mid-switch can no longer kill activate-rs and leave
      # the host stranded between generations with no magic rollback left.
      status=0
      systemd-run \
        --quiet --wait --collect \
        --property=CollectMode=inactive-or-failed \
        --unit="$unit" \
        --uid="$user" \
        --setenv=PATH="$PATH" \
        -- "$@" || status=$?

      sleep 1
      exit "$status"
    '';
  };
in
{
  environment.systemPackages = [
    rebuild
    deployStatus
    activateDetached
  ];
}

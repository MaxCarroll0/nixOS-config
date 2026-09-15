# Amazon WorkSpaces client, split-tunnelled, with a distrobox fallback.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  overrides = import ../lib/overrides.nix { inherit lib; };
  cfg = config.local.workspaces;

  # nixpkgs still pins the 2025 build, whose .deb AWS has deleted, and its fixup
  # is written against a dcv/ subdirectory the 2026 bundle no longer has.
  aws-workspaces =
    overrides.againstVersion "aws-workspaces" "2025.0.5296" pkgs.aws-workspaces.version
      (pkgs.callPackage ../pkgs/aws-workspaces.nix { });

  workspacesBoxProvision = pkgs.writeText "workspaces-box-provision.sh" (
    builtins.readFile ./workspaces-box-provision.sh
  );

  # Fallback for when AWS rotates the .deb and the packaged client stops
  # building: apt inside the container tracks upstream on its own.
  workspaces-box = pkgs.writeShellApplication {
    name = "workspaces-box";
    runtimeInputs = with pkgs; [
      distrobox
      podman
    ];
    text = ''
      box=workspaces
      image=docker.io/library/ubuntu:24.04
      setup=0

      if [ "''${1:-}" = "--setup" ]; then
        shift
        setup=1
        if podman container exists "$box"; then
          distrobox rm --force "$box"
        fi
      fi

      if ! podman container exists "$box"; then
        distrobox create --name "$box" --image "$image" --yes
        distrobox enter --name "$box" -- bash -s <${workspacesBoxProvision}
      fi

      if [ "$setup" = 1 ]; then
        distrobox enter --name "$box" -- workspacesclient --version
        exit 0
      fi

      exec distrobox enter --name "$box" -- workspacesclient "$@"
    '';
  };

  # DCV streams over UDP and WorkSpaces directories are commonly IP-restricted.
  workspaces-novpn = pkgs.writeShellScriptBin "workspaces-novpn" ''
    export WORKSPACES_URI="$1"
    if [ -n "$WORKSPACES_URI" ]; then
      exec /run/wrappers/bin/sg novpn -c '${lib.getExe aws-workspaces} "$WORKSPACES_URI"'
    else
      exec /run/wrappers/bin/sg novpn -c '${lib.getExe aws-workspaces}'
    fi
  '';
in
{
  options.local.workspaces.enable = lib.mkEnableOption "the Amazon WorkSpaces client";

  config = lib.mkIf cfg.enable {
    home.packages = [
      workspaces-novpn
      workspaces-box
    ];

    xdg.desktopEntries.workspaces-novpn = {
      name = "Amazon WorkSpaces";
      genericName = "Remote Desktop";
      exec = "workspaces-novpn %u";
      icon = "${aws-workspaces}/share/icons/hicolor/256x256/apps/com.amazon.workspacesclient.png";
      terminal = false;
      categories = [
        "Network"
        "RemoteAccess"
      ];
      mimeType = [ "x-scheme-handler/workspaces" ];
      settings.StartupWMClass = "workspacesclient";
    };

    xdg.mimeApps.defaultApplications."x-scheme-handler/workspaces" = "workspaces-novpn.desktop";
  };
}

# Structured telemetry for every Nix client invocation.

{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

let
  cfg = config.local.monitoring.nixBuilds;
  nixCommands = [
    "nix"
    "nix-build"
    "nix-channel"
    "nix-collect-garbage"
    "nix-copy-closure"
    "nix-env"
    "nix-hash"
    "nix-instantiate"
    "nix-prefetch-url"
    "nix-shell"
    "nix-store"
  ];
  observer = pkgs.writeShellApplication {
    name = "nix-observe";
    runtimeInputs = [
      pkgs.nix-output-monitor
      pkgs.python3
    ];
    text = ''
      exec python3 ${./nix-observer.py} "$@"
    '';
  };
  observedWrapper =
    name: binary:
    pkgs.writeShellApplication {
      name = "${name}-observed";
      text = ''
        ${lib.optionalString (config.local.vpn.enable or false) "export NIX_OBSERVER_NOVPN=1"}
        export NIX_OBSERVER_NOM=${lib.getExe pkgs.nix-output-monitor}
        export NIX_OBSERVER_REAL_NIX=${config.nix.package}/bin/nix
        export NIX_OBSERVER_REAL_NIX_STORE=${config.nix.package}/bin/nix-store
        exec ${lib.getExe observer} --command ${lib.escapeShellArg name} --real ${lib.escapeShellArg binary} "$@"
      '';
    };
  observedNix = observedWrapper "nix" "${config.nix.package}/bin/nix";
  contextWrapper =
    name: kind: binary:
    pkgs.writeShellApplication {
      name = "${name}-observed";
      text = ''
        export NIX_OBSERVER_KIND=${lib.escapeShellArg kind}
        ${lib.optionalString (config.local.vpn.enable or false) "export NIX_OBSERVER_NOVPN=1"}
        exec ${binary} "$@"
      '';
    };
  homeManager = inputs.home-manager.packages.${pkgs.stdenv.hostPlatform.system}.default;
  wrapper = source: {
    inherit source;
    owner = "root";
    group = "root";
    permissions = "u+rx,g+rx,o+rx";
  };
in

{
  options.local.monitoring.nixBuilds = {
    enable = lib.mkEnableOption "structured Nix build observation";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ observer ];

    security.wrappers =
      lib.genAttrs nixCommands (
        command:
        wrapper "${
          if command == "nix" then
            observedNix
          else
            observedWrapper command "${config.nix.package}/bin/${command}"
        }/bin/${command}-observed"
      )
      // {
        nixos-rebuild = wrapper "${
          contextWrapper "nixos-rebuild" "rebuild" "${pkgs.nixos-rebuild-ng}/bin/nixos-rebuild"
        }/bin/nixos-rebuild-observed";
        nh = wrapper "${contextWrapper "nh" "rebuild" "${lib.getExe pkgs.nh}"}/bin/nh-observed";
        home-manager = wrapper "${
          contextWrapper "home-manager" "home-rebuild" "${lib.getExe homeManager}"
        }/bin/home-manager-observed";
      };

    systemd.services.nixos-upgrade = lib.mkIf config.system.autoUpgrade.enable {
      environment = {
        NIX_OBSERVER_KIND = "rebuild";
        NIX_OBSERVER_UNATTENDED = "1";
        NIX_OBSERVER_NOM = lib.getExe pkgs.nix-output-monitor;
      }
      // lib.optionalAttrs (config.local.vpn.enable or false) { NIX_OBSERVER_NOVPN = "1"; };
      path = lib.mkBefore [ observedNix ];
    };
  };
}

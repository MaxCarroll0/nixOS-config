# Pins the generation that last booted successfully into its own bootloader profile.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.lastGoodBoot;
  profileDir = "/nix/var/nix/profiles/system-profiles";
  profile = "${profileDir}/${cfg.profileName}";

  pin = pkgs.writeShellApplication {
    name = "pin-last-good-boot";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
    ];
    text = ''
      booted=$(readlink -f /run/booted-system)
      if [ ! -e "$booted/nixos-version" ]; then
        echo "no booted system to pin" >&2
        exit 0
      fi
      if [ "$(readlink -f ${profile} 2>/dev/null || true)" = "$booted" ]; then
        exit 0
      fi

      mkdir -p ${profileDir}
      nix-env --profile ${profile} --set "$booted"
      nix-env --profile ${profile} --delete-generations +${toString cfg.keep}

      ${lib.optionalString cfg.refreshBootloader ''
        /run/current-system/bin/switch-to-configuration boot || true
      ''}
    '';
  };
in

{
  options.local.lastGoodBoot = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.boot.loader.grub.enable;
      description = "Keep the last successfully booted generation in its own boot profile.";
    };

    profileName = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_]+";
      default = "last_good";
      description = "System profile name; GRUB titles its submenu after it.";
    };

    keep = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Generations of the profile to retain.";
    };

    settleMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Uptime after which the current boot counts as successful.";
    };

    refreshBootloader = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Reinstall the bootloader when the pin moves, so the entry is never stale.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.pin-last-good-boot = {
      description = "Pin the last successfully booted generation";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe pin;
      };
    };

    systemd.timers.pin-last-good-boot = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.settleMinutes}m";
        AccuracySec = "1m";
      };
    };
  };
}

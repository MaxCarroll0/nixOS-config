# Settings shared by every host: nix, secrets, locale, users, upgrades.

{
  config,
  pkgs,
  lib,
  facts,
  ...
}:

let
  flakePath = "/home/max/.config/nix";
  cfg = config.local.users;

  selfName = config.networking.hostName;

  pinsFile = ../../hosts + "/${selfName}/pins.nix";
  pinsBaked = if builtins.pathExists pinsFile then builtins.hashFile "sha256" pinsFile else "none";
  pins = import ../../lib/pins.nix {
    root = ../..;
    host = selfName;
  };

  upgradeAllowed = pkgs.writeShellApplication {
    name = "nixos-upgrade-allowed";
    runtimeInputs = [
      pkgs.git
      pkgs.gnugrep
      pkgs.jq
      pkgs.util-linux
      pkgs.coreutils
      config.nix.package
    ];
    text = ''
      metrics=/var/lib/node-exporter-textfile/autoupgrade.prom

      verdict() {
        if [ -d "$(dirname "$metrics")" ]; then
          {
            printf 'node_autoupgrade_blocked{reason="%s"} %s\n' "$2" "$1" > "$metrics.tmp" \
              && mv "$metrics.tmp" "$metrics"
          } || echo "could not record the upgrade verdict as a metric" >&2
        fi
        [ "$1" = 0 ] || echo "skipping upgrade: $3" >&2
        exit "$1"
      }

      [ -d ${flakePath}/.git ] || verdict 0 none "no clone to guard"

      git config --global --get-all safe.directory | grep -qxF ${flakePath} \
        || git config --global --add safe.directory ${flakePath}
      runuser -u max -- git -C ${flakePath} fetch -q origin || verdict 1 fetch-failed "cannot reach origin"

      pinsAt() {
        if git -C ${flakePath} cat-file -e "origin/HEAD:hosts/${selfName}/pins.nix" 2>/dev/null; then
          git -C ${flakePath} show "origin/HEAD:hosts/${selfName}/pins.nix" | sha256sum | cut -d' ' -f1
        else
          echo none
        fi
      }

      pinsOnOrigin=$(pinsAt)
      [ "$pinsOnOrigin" = ${pinsBaked} ] \
        || verdict 1 pins-changed "hosts/${selfName}/pins.nix differs on origin from the copy this system was built with"

      if held=$(jq -r 'keys | join(", ")' /var/lib/flake-sync/held.json 2>/dev/null) && [ -n "$held" ]; then
        verdict 1 held "this host holds back $held until the shared lock builds here again"
      fi

      stamp="$(git -C ${flakePath} rev-parse origin/HEAD) $pinsOnOrigin"
      if [ "$(cat /var/lib/nixos-upgrade/last 2>/dev/null)" = "$stamp" ]; then
        verdict 1 unchanged "origin/main and its pins are the state last upgraded to"
      fi

      running=$(nixos-version --configuration-revision 2>/dev/null || true)

      case "$running" in
        "")
          verdict 1 unknown-running "the running system records no revision, so nothing can be shown to supersede it"
          ;;
        *-dirty)
          verdict 1 dirty-running "the running system was built from an uncommitted tree, so no commit supersedes it"
          ;;
      esac

      if ! git -C ${flakePath} merge-base --is-ancestor "$running" origin/HEAD; then
        verdict 1 unpushed-running "the running revision $running is not an ancestor of origin, so upgrading would revert it"
      fi

      printf '%s\n' "$stamp" > /var/lib/nixos-upgrade/pending
      verdict 0 none "forward from $running"
    '';
  };
  onTailnet = lib.filterAttrs (_: f: f ? tailscale) facts;
  tailnetNames = lib.mapAttrs (_: f: f.tailscale or f.tailnetAddress) (
    lib.filterAttrs (_: f: f ? tailscale || f ? tailnetAddress) facts
  );
  wakeable = lib.filterAttrs (name: f: name != selfName && f ? mac) facts;

  editSecrets = pkgs.writeShellApplication {
    name = "edit-secrets";
    text = ''
      ageKey=$(sudo ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key)
      export SOPS_AGE_KEY="$ageKey"
      exec ${pkgs.sops}/bin/sops ${flakePath}/secrets/secrets.yaml
    '';
  };

  # Every recipe addresses the flake with relative paths, so running one from
  # elsewhere needs both the justfile and the working directory pointed at the clone.
  nixConfig = pkgs.writeShellApplication {
    name = "nix-config";
    runtimeInputs = [ pkgs.just ];
    text = ''
      exec just --justfile ${flakePath}/justfile --working-directory ${flakePath} "$@"
    '';
  };

  projectClosureRetention = pkgs.writeShellApplication {
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

in

{
  imports = [
    ./deploy.nix
    ./dev-build.nix
    ./flake-sync.nix
    ./peer-transport.nix
    ./nix-observer.nix
    ./unclean-boot.nix
    ./last-good-boot.nix
  ];

  options.local.users.sopsPasswords = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example = {
      alice = "alice-password-hash";
    };
    description = "Accounts whose password hash comes from sops.";
  };

  config = {
    # Proton owns resolv.conf and Tailscale DNS is deliberately disabled, while
    # Tailscale Serve still requires the node's MagicDNS host name.
    networking.hosts = lib.mapAttrs' (
      name: address:
      lib.nameValuePair address [
        name
        "${name}.taild5b88a.ts.net"
      ]
    ) tailnetNames;

    local.peerTransport = {
      enable = true;
      peers = lib.mapAttrs (_: f: { tailscaleAddress = f.tailscale; }) onTailnet;
    };

    local.wake = {
      peers = lib.mapAttrs (_: f: { mac = lib.mkDefault f.mac; }) wakeable;
      relays = lib.mapAttrs (_: f: f.tailscale) (lib.filterAttrs (name: _: name != selfName) onTailnet);
    };
    boot.loader.grub.enable = lib.mkDefault true;
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
    boot.loader.efi.efiSysMountPoint = lib.mkDefault "/boot";
    boot.loader.grub.efiSupport = lib.mkDefault true;
    boot.loader.grub.device = lib.mkDefault "nodev";
    boot.loader.grub.configurationLimit = lib.mkDefault 20;

    boot.kernelParams = [
      "zswap.enabled=1"
      "zswap.compressor=zstd"
      "zswap.zpool=zsmalloc"
      "zswap.max_pool_percent=20"
    ];

    swapDevices = [
      {
        device = "/swapfile";
        size = 8 * 1024;
        randomEncryption.enable = true;
      }
    ];

    # randomEncryption gives the swapfile a new UUID every boot, so a hibernation
    # image is unresumable and its stale HibernateLocation EFI variable costs the
    # next boot a two-minute device timeout.
    systemd.sleep.settings.Sleep = {
      AllowHibernation = false;
      AllowHybridSleep = false;
      AllowSuspendThenHibernate = false;
    };

    services.earlyoom = {
      enable = true;
      freeMemThreshold = lib.mkDefault 5;
      freeSwapThreshold = lib.mkDefault 10;
    };

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    local.monitoring.nixBuilds.enable = true;

    services.journald.extraConfig = ''
      Storage=persistent
      SystemMaxUse=1G
    '';

    nix.settings.connect-timeout = 5;
    # rebuild evaluates the flake again under sudo, and git refuses a repo owned
    # by another user.
    environment.etc."gitconfig".text = ''
      [safe]
        directory = ${flakePath}
    '';

    nix.settings.fallback = true;
    nix.settings.builders-use-substitutes = true;
    nix.settings.substituters = [
      "https://hyprland.cachix.org"
      "https://nix-community.cachix.org"
      "https://nixos-raspberrypi.cachix.org"
    ];
    nix.settings.trusted-substituters = [
      "https://hyprland.cachix.org"
      "https://nix-community.cachix.org"
      "https://nixos-raspberrypi.cachix.org"
    ];
    nix.settings.trusted-public-keys = [
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
    nix.settings.trusted-users = [
      "root"
      "@wheel"
    ];

    nix.optimise.automatic = true;
    nix.optimise.dates = [ "*-*-2,16 04:15:00" ];

    programs.nh = {
      enable = true;
      flake = flakePath;
      clean = {
        enable = true;
        dates = "daily";
        extraArgs = "--keep 10 --keep-since 14d";
      };
    };

    systemd.services.nh-clean.preStart = /* bash */ ''
      ${projectClosureRetention}/bin/project-closure-retention --apply
    '';

    local.users.sopsPasswords.max = "max-password-hash";
    users.mutableUsers = false;

    # Declared here whoever consumes them: Home Manager runs as the user and
    # cannot read a root-only host key.
    sops = {
      defaultSopsFile = ../../secrets/secrets.yaml;
      defaultSopsFormat = "yaml";

      secrets = {
        github-API.owner = "max";
        exercism-API.owner = "max";
        claude-swap-export = {
          sopsFile = ../../secrets/claude-swap.json;
          format = "json";
          owner = "max";
          mode = "0400";
        };
      }
      # Decrypted to /run/secrets-for-users before accounts exist, so these
      # cannot take an owner.
      // lib.mapAttrs' (_: secret: lib.nameValuePair secret { neededForUsers = true; }) cfg.sopsPasswords;

      templates."conf-access-tokens" = {
        content = "extra-access-tokens = github.com=${config.sops.placeholder.github-API}";
        owner = "max";
      };
    };

    # !include, not readFile: readFile which needs--impure
    nix.extraOptions = "!include ${config.sops.templates."conf-access-tokens".path}";

    # An upgrade must never move a host backwards. ExecCondition, not preStart:
    # a non-zero condition skips the unit cleanly instead of marking it failed.
    systemd.services.nixos-upgrade.serviceConfig = {
      ExecCondition = lib.getExe upgradeAllowed;
      ExecStartPost = "-${lib.getExe' pkgs.coreutils "mv"} -f /var/lib/nixos-upgrade/pending /var/lib/nixos-upgrade/last";
      StateDirectory = "nixos-upgrade";
      MemoryHigh = "3G";
      CPUWeight = "idle";
    };

    system.autoUpgrade = {
      enable = lib.mkDefault false;
      allowReboot = true;
      flake = "git+file://${flakePath}?ref=refs/remotes/origin/main#${config.networking.hostName}";
      flags = [ "-L" ] ++ pins.argv;
      dates = "daily";
      randomizedDelaySec = "45min";
      rebootWindow = {
        lower = "03:00";
        upper = "05:00";
      };
    };

    security.pki.certificates = [ (builtins.readFile ../../keys/home-ca.crt) ];

    networking.networkmanager.enable = true;

    networking.networkmanager.wifi.powersave = false;

    time.timeZone = "Europe/London";

    i18n.defaultLocale = "en_GB.UTF-8";

    i18n.extraLocaleSettings = {
      LC_ADDRESS = "en_GB.UTF-8";
      LC_IDENTIFICATION = "en_GB.UTF-8";
      LC_MEASUREMENT = "en_GB.UTF-8";
      LC_MONETARY = "en_GB.UTF-8";
      LC_NAME = "en_GB.UTF-8";
      LC_NUMERIC = "en_GB.UTF-8";
      LC_PAPER = "en_GB.UTF-8";
      LC_TELEPHONE = "en_GB.UTF-8";
      LC_TIME = "en_GB.UTF-8";
    };

    console.keyMap = "uk";

    users.users = lib.mkMerge [
      (lib.mapAttrs (_: secret: {
        hashedPasswordFile = config.sops.secrets.${secret}.path;
      }) cfg.sopsPasswords)
      {
        max = {
          isNormalUser = true;
          description = "Max Carroll";
          extraGroups = [
            "networkmanager"
            "wheel"
            "keys"
          ];
        };
      }
    ];

    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = [
      editSecrets
      nixConfig
      projectClosureRetention
      pkgs.nix-sweep
      pkgs.git
    ];

    system.stateVersion = lib.mkDefault "25.05";

    warnings = lib.mapAttrsToList (
      name: _:
      "${name} has a sops password but users.mutableUsers is true, so it only applies at account creation."
    ) (lib.optionalAttrs config.users.mutableUsers cfg.sopsPasswords);
  };
}

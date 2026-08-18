# NAS enrolment: accounts are minted locked; the owner sets their own passwords with a one-time token.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.nas;
  ecfg = cfg.enroll;

  issue = pkgs.writeShellApplication {
    name = "nas-enroll-issue";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    text = ''
      name=''${1:?usage: nas-enroll-issue <account>}
      getent passwd "$name" >/dev/null || { echo "no such account: $name" >&2; exit 1; }

      token=$(openssl rand -hex 16)
      expires=$(( $(date +%s) + ${toString ecfg.tokenLifetimeSeconds} ))
      printf '%s %s\n' "$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)" "$expires" \
        > ${ecfg.stateDir}/"$name"
      chmod 600 ${ecfg.stateDir}/"$name"

      echo "$token"
    '';
  };

  redeem = pkgs.writeShellApplication {
    name = "nas-enroll";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.shadow
      pkgs.samba
    ];
    text = ''
      name=''${1:?usage: nas-enroll <account>}
      state=${ecfg.stateDir}/"$name"
      [ -f "$state" ] || { echo "no enrolment pending for $name" >&2; exit 1; }

      read -r want expires < "$state"
      if [ "$(date +%s)" -gt "$expires" ]; then
        rm -f "$state"
        echo "enrolment token expired; ask for a new one" >&2
        exit 1
      fi

      printf 'Enrolment token: ' >&2
      read -r -s token; echo >&2
      got=$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)
      if [ "$got" != "$want" ]; then
        echo "token rejected" >&2
        exit 1
      fi

      printf 'New password: ' >&2
      read -r -s pw1; echo >&2
      printf 'Repeat: ' >&2
      read -r -s pw2; echo >&2
      [ "$pw1" = "$pw2" ] || { echo "passwords differ" >&2; exit 1; }
      [ ''${#pw1} -ge ${toString ecfg.minPasswordLength} ] || {
        echo "password must be at least ${toString ecfg.minPasswordLength} characters" >&2
        exit 1
      }

      printf '%s:%s' "$name" "$pw1" | chpasswd
      printf '%s\n%s\n' "$pw1" "$pw1" | smbpasswd -s -a "$name"
      unset pw1 pw2 token

      rm -f "$state"
      echo "enrolled $name"
    '';
  };
in

{
  options.local.nas.enroll = {
    enable = lib.mkEnableOption "one-time enrolment tokens so account owners set their own passwords";

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nas-enroll";
      description = "Where pending enrolments are held, as a token hash and an expiry.";
    };

    tokenLifetimeSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 172800;
      description = "How long an issued token stays valid.";
    };

    minPasswordLength = lib.mkOption {
      type = lib.types.ints.positive;
      default = 12;
      description = "Shortest password an owner may set.";
    };

    web = {
      enable = lib.mkEnableOption "the enrolment web form";

      port = lib.mkOption {
        type = lib.types.port;
        default = 8081;
        description = "Loopback port the enrolment form listens on.";
      };

      hostname = lib.mkOption {
        type = lib.types.str;
        default = "enroll";
        description = "Virtual host serving the form on the tailnet.";
      };

      interface = lib.mkOption {
        type = lib.types.str;
        default = "tailscale0";
        description = "Interface the form is reachable on; never the public one.";
      };
    };
  };

  config = lib.mkIf (cfg.enable && ecfg.enable) {
    environment.systemPackages = [
      issue
      redeem
    ];

    systemd.tmpfiles.rules = [ "d ${ecfg.stateDir} 0700 root root - -" ];

    security.sudo.extraRules = [
      {
        groups = lib.attrNames cfg.accounts;
        commands = [
          {
            command = "/run/current-system/sw/bin/nas-enroll";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    systemd.services.nas-enroll-web = lib.mkIf ecfg.web.enable {
      description = "NAS enrolment web form";
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.shadow
        pkgs.samba
      ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./nas-enroll-web.py} --listen 127.0.0.1 --port ${toString ecfg.web.port} --state-dir ${ecfg.stateDir} --min-length ${toString ecfg.minPasswordLength}";
        Restart = "on-failure";
        RestartSec = 5;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = false;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_UNIX"
        ];
        ReadWritePaths = [
          ecfg.stateDir
          "/etc"
          "/var/lib/samba"
        ];
        MemoryMax = "64M";
      };
    };

    services.nginx = lib.mkIf ecfg.web.enable {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts.${ecfg.web.hostname}.locations."/".proxyPass =
        "http://127.0.0.1:${toString ecfg.web.port}";
    };

    networking.firewall.interfaces.${ecfg.web.interface}.allowedTCPPorts = lib.mkIf ecfg.web.enable [
      80
    ];
  };
}

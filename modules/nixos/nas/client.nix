# Automatic encrypted NAS mount through the shared LAN-first peer transport.

{ config, pkgs, lib, ... }:

let
  cfg = config.local.nasClient;
  setPassword = pkgs.writeShellApplication {
    name = "nas-set-password";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "run with PAM sudo: sudo nas-set-password" >&2
        exit 1
      fi
      read -r -s -p "SMB password for ${cfg.share}: " password
      printf '\n'
      install -d -m 0700 ${lib.escapeShellArg (builtins.dirOf cfg.credentialsFile)}
      umask 077
      {
        printf 'username=%s\n' ${lib.escapeShellArg cfg.share}
        printf 'password=%s\n' "$password"
      } > ${lib.escapeShellArg cfg.credentialsFile}
      systemctl restart mnt-nas.automount 2>/dev/null || true
    '';
  };
in
{
  options.local.nasClient = {
    enable = lib.mkEnableOption "automatic LAN-first NAS mount";
    peer = lib.mkOption { type = lib.types.str; default = "pi"; };
    share = lib.mkOption { type = lib.types.str; default = "max"; };
    mountPoint = lib.mkOption { type = lib.types.str; default = "/mnt/nas"; };
    proxyPort = lib.mkOption { type = lib.types.port; default = 1445; };
    credentialsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nas-client/credentials";
      description = "Root-only cifs credentials file containing username and password.";
    };
  };

  config = lib.mkIf cfg.enable {
    local.peerTransport.forwards.nas = {
      inherit (cfg) peer;
      listenPort = cfg.proxyPort;
      targetPort = 445;
    };

    environment.systemPackages = [ pkgs.cifs-utils setPassword ];
    systemd.tmpfiles.rules = [ "d /var/lib/nas-client 0700 root root - -" ];

    fileSystems.${cfg.mountPoint} = {
      device = "//127.0.0.1/${cfg.share}";
      fsType = "cifs";
      options = [
        "credentials=${cfg.credentialsFile}"
        "port=${toString cfg.proxyPort}"
        "vers=3.1.1"
        "seal"
        "cache=strict"
        "uid=max"
        "gid=users"
        "file_mode=0600"
        "dir_mode=0700"
        "noserverino"
        "nofail"
        "x-systemd.automount"
        "x-systemd.idle-timeout=10min"
        "x-systemd.mount-timeout=15s"
        "x-systemd.requires=peer-forward-nas.service"
        "_netdev"
      ];
    };
  };
}

# Transmission confined to the Proton tunnel, no forwarded port.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.local.torrent;
  tunnelInterfaces = [ config.local.vpn.interface ];
  tunnelUnits = map (i: "wg-quick-${i}.service") tunnelInterfaces;
in

{
  options.local.torrent = {
    enable = lib.mkEnableOption "the Transmission daemon";

    downloadDir = lib.mkOption {
      type = lib.types.path;
      default = "/home/max/torrents";
    };

    peerPort = lib.mkOption {
      type = lib.types.port;
      default = 51413;
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "max";
      description = "Account added to the transmission group to reach the downloads.";
    };

    downloadLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = 4000;
      description = "Download ceiling in kB/s, null for unlimited.";
    };

    uploadLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = 4000;
      description = "Upload ceiling in kB/s, null for unlimited.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.transmission = {
      enable = true;
      package = pkgs.transmission_4;
      openPeerPorts = false;
      openRPCPort = false;
      downloadDirPermissions = "770";

      settings = {
        download-dir = "${cfg.downloadDir}/complete";
        incomplete-dir = "${cfg.downloadDir}/incomplete";
        incomplete-dir-enabled = true;

        rpc-bind-address = "127.0.0.1";
        rpc-authentication-required = false;

        peer-port = cfg.peerPort;
        peer-port-random-on-start = false;
        port-forwarding-enabled = false;

        dht-enabled = true;
        pex-enabled = true;
        utp-enabled = true;

        lpd-enabled = false;

        speed-limit-down-enabled = cfg.downloadLimit != null;
        speed-limit-down = lib.mkIf (cfg.downloadLimit != null) cfg.downloadLimit;
        speed-limit-up-enabled = cfg.uploadLimit != null;
        speed-limit-up = lib.mkIf (cfg.uploadLimit != null) cfg.uploadLimit;

        encryption = 2;
        umask = "002";
        ratio-limit-enabled = false;
      };
    };

    systemd.services = {
      transmission = {
        # Upstream leaves transmission-setup only before/partOf, so nothing pulls it in.
        requires = [ "transmission-setup.service" ];
        after = [ "transmission-setup.service" ] ++ tunnelUnits;
        # RestrictNetworkInterfaces resolves interface indexes once, at exec.
        partOf = tunnelUnits;
        serviceConfig.RestrictNetworkInterfaces = [ "lo" ] ++ tunnelInterfaces;
      };
      transmission-setup.unitConfig.RequiresMountsFor = cfg.downloadDir;
    }
    // lib.genAttrs (map (i: "wg-quick-${i}") tunnelInterfaces) (_: {
      wants = [ "transmission.service" ];
    });

    users.users.${cfg.user}.extraGroups = [ config.services.transmission.group ];

    environment.systemPackages = [
      config.services.transmission.package
      pkgs.tremc
    ];
  };
}

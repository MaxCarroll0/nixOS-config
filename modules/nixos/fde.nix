# LUKS root, optionally unlockable over SSH from initrd.

{
  config,
  lib,
  ...
}:

let
  cfg = config.local.fde;
in

{
  options.local.fde = {
    enable = lib.mkEnableOption "an encrypted root filesystem";

    device = lib.mkOption {
      type = lib.types.str;
      example = "/dev/disk/by-uuid/....";
      description = "The LUKS container holding the root filesystem.";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "cryptroot";
      description = "Device mapper name for the opened container.";
    };

    remoteUnlock = {
      enable = lib.mkEnableOption "supplying the passphrase over SSH from initrd";

      port = lib.mkOption {
        type = lib.types.port;
        default = 2222;
      };

      authorizedKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Keys allowed to unlock this machine remotely.";
      };

      # Kept out of the store and off the real host key: initrd contents land on
      # the unencrypted boot partition.
      hostKeyPath = lib.mkOption {
        type = lib.types.str;
        default = "/etc/secrets/initrd/ssh_host_ed25519_key";
      };

      kernelModules = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "r8169" ];
        description = "NIC drivers initrd needs to reach the network.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        boot.initrd.luks.devices.${cfg.name}.device = cfg.device;
      }

      (lib.mkIf cfg.remoteUnlock.enable {
        boot.initrd.availableKernelModules = cfg.remoteUnlock.kernelModules;
        boot.kernelParams = [ "ip=dhcp" ];

        boot.initrd.network = {
          enable = true;
          ssh = {
            enable = true;
            inherit (cfg.remoteUnlock) port authorizedKeys;
            hostKeys = [ cfg.remoteUnlock.hostKeyPath ];
          };
          postCommands = ''
            echo 'cryptsetup-askpass; exit' >> /root/.profile
          '';
        };

        assertions = [
          {
            assertion = cfg.remoteUnlock.authorizedKeys != [ ];
            message = "local.fde.remoteUnlock has no authorizedKeys, so nobody could unlock remotely.";
          }
          {
            assertion = cfg.remoteUnlock.kernelModules != [ ];
            message = "local.fde.remoteUnlock needs the NIC driver in kernelModules or initrd has no network.";
          }
        ];

        warnings = lib.optional config.system.autoUpgrade.allowReboot ''
          system.autoUpgrade.allowReboot with an encrypted root leaves this host at
          the passphrase prompt after an unattended reboot.
        '';
      })
    ]
  );
}

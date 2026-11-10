# vm-guard: run heavy commands at idle priority beside the game VM, opt-in per command.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.local.vmGuard;
  slice = "vmguard.slice";
  scopePrefix = "vm-guard-";

  client = pkgs.writeShellApplication {
    name = "vm-guard";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      if [ $# -eq 0 ] || [ "$1" = --help ]; then
        echo "usage: vm-guard COMMAND [ARG ...]" >&2
        echo "Runs COMMAND in ${slice}: it gets every CPU and all IO the VM leaves unused, and yields the moment the VM wants them." >&2
        exit 2
      fi
      exec systemd-run --scope --quiet --slice=${slice} --unit="${scopePrefix}$$" -- "$@"
    '';
  };
in
{
  options.local.vmGuard.enable = lib.mkEnableOption "the opt-in vm-guard wrapper for heavy commands";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ client ];

    systemd.slices.vmguard = {
      description = "Work that runs only on resources the VM leaves idle";
      sliceConfig = {
        CPUWeight = "idle";
        IOWeight = 1;
      };
    };

    systemd.slices.machine.sliceConfig.IOWeight = 10000;

    systemd.services.nix-daemon.serviceConfig.Slice = slice;

    security.polkit.extraConfig = ''
      polkit.addRule(function (action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units"
            && /^${scopePrefix}[0-9]+\.scope$/.test(action.lookup("unit") || "")
            && action.lookup("verb") == "start"
            && subject.user == "max") {
          return polkit.Result.YES;
        }
      });
    '';
  };
}

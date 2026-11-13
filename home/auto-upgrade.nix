# Weekly home upgrade that applies every input bump that builds and holds back the ones that don't.

{ pkgs, ... }:

let
  flakeDir = "/home/max/.config/nix";

  homeUpgrade = pkgs.writeShellApplication {
    name = "home-upgrade";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.git
      pkgs.jq
      pkgs.hostname
    ];
    text = ''
      state="''${XDG_STATE_HOME:-$HOME/.local/state}/home-upgrade"
      mkdir -p "$state"
      target="${flakeDir}#homeConfigurations.\"$USER@$(hostname)\".activationPackage"

      build() {
        nix build --no-write-lock-file --reference-lock-file "$1" -o "$state/result" "$target"
      }

      bump() {
        local from=$1 to=$2
        shift 2
        nix flake update --flake ${flakeDir} --reference-lock-file "$from" --output-lock-file "$to" "$@"
      }

      same_lock() {
        cmp -s <(jq -S .nodes "$1") <(jq -S .nodes "$2")
      }

      cp ${flakeDir}/flake.lock "$state/base.lock"
      held=()

      bump "$state/base.lock" "$state/all.lock"
      if build "$state/all.lock"; then
        cp "$state/all.lock" "$state/good.lock"
      else
        build "$state/base.lock" || {
          echo "<3>the configuration does not build even without bumping any input"
          exit 1
        }
        cp "$state/base.lock" "$state/good.lock"
        mapfile -t pending < <(jq -r '.nodes.root.inputs | keys[]' "$state/base.lock")
        progressed=1
        while [ "''${#pending[@]}" -gt 0 ] && [ "$progressed" = 1 ]; do
          progressed=0
          held=()
          for input in "''${pending[@]}"; do
            bump "$state/good.lock" "$state/try.lock" "$input"
            same_lock "$state/good.lock" "$state/try.lock" && continue
            if build "$state/try.lock"; then
              cp "$state/try.lock" "$state/good.lock"
              progressed=1
            else
              held+=("$input")
            fi
          done
          pending=("''${held[@]}")
        done
        build "$state/good.lock"
      fi

      printf '%s\n' "''${held[@]}" > "$state/held"
      "$state/result/activate"

      if [ "''${#held[@]}" -gt 0 ]; then
        echo "<4>held back inputs whose bump does not build: ''${held[*]}"
      fi
    '';
  };
in
{
  home.packages = [ homeUpgrade ];

  systemd.user.services.home-upgrade = {
    Unit.Description = "Home Manager upgrade, holding back inputs that break the build";
    Service = {
      Type = "oneshot";
      Environment = [
        "NIX_OBSERVER_PLAIN=1"
        "PATH=/run/current-system/sw/bin:/home/max/.nix-profile/bin"
      ];
      ExecStart = "${homeUpgrade}/bin/home-upgrade";
    };
  };

  systemd.user.timers.home-upgrade = {
    Unit.Description = "Weekly Home Manager upgrade";
    Timer = {
      OnCalendar = "weekly";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}

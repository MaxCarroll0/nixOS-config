# Weekly flake sync on every host: bump and push the shared lock, adopt it locally, upgrade home.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  flakePath = "/home/max/.config/nix";
  hostName = config.networking.hostName;

  buildTargets = pkgs.writeText "flake-sync-targets.nix" ''
    { repo, platforms }:
    let
      flake = builtins.getFlake "git+file://''${repo}";
      buildable = host: builtins.elem flake.nixosConfigurations.''${host}.pkgs.stdenv.hostPlatform.system platforms;
      hosts = builtins.filter buildable (builtins.attrNames flake.deploy.nodes);
      homes = builtins.filter (host: flake.homeConfigurations ? "max@''${host}") hosts;
    in
    builtins.concatStringsSep "\n" (
      map (host: "git+file://''${repo}#nixosConfigurations.''${host}.config.system.build.toplevel") hosts
      ++ map (host: "git+file://''${repo}#homeConfigurations.\"max@''${host}\".activationPackage") homes
    )
  '';

  headRegressions = pkgs.writeText "head-regressions.jq" ''
    def roots($lock):
      $lock.nodes.root.inputs
      | with_entries(select(.value | type == "string") | .value = $lock.nodes[.value]);
    roots($old[0]) as $o
    | roots($new[0]) as $n
    | $o | keys[]
    | select(
        $n[.] != null
        and $o[.].original == $n[.].original
        and $n[.].original.rev == null
        and $n[.].locked.lastModified < $o[.].locked.lastModified
      )
  '';

  flakeSync = pkgs.writeShellApplication {
    name = "flake-sync";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.diffutils
      pkgs.git
      pkgs.jq
      pkgs.openssh
    ];
    text = ''
      state=''${STATE_DIRECTORY:-$HOME/.local/state/flake-sync}
      repo=$state/repo
      work=${flakePath}
      mkdir -p "$state"
      [ -d "$repo/.git" ] || git clone -q "$(git -C "$work" remote get-url origin)" "$repo"

      read -ra platformList <<< "$(nix config show system) $(nix config show extra-platforms)"
      platforms=$(printf '"%s" ' "''${platformList[@]}")

      regressions() {
        jq -rn --slurpfile old "$1" --slurpfile new "$2" -f ${headRegressions}
      }

      same_lock() {
        cmp -s <(jq -S .nodes "$1") <(jq -S .nodes "$2")
      }

      build() {
        rm -f "$state"/result*
        nix build --no-write-lock-file --reference-lock-file "$1" -o "$state/result" "''${targets[@]}"
      }

      bump() {
        local from=$1 to=$2
        shift 2
        nix flake update --refresh --flake "git+file://$repo" \
          --reference-lock-file "$from" --output-lock-file "$to" "$@"
      }

      publish() {
        for attempt in 1 2 3; do
          git -C "$repo" fetch -q origin
          git -C "$repo" reset -q --hard origin/main
          mapfile -t targets < <(nix eval --impure --raw \
            --expr "import ${buildTargets} { repo = \"$repo\"; platforms = [ $platforms ]; }")
          cp "$repo/flake.lock" "$state/base.lock"
          held=()

          bump "$state/base.lock" "$state/all.lock"
          stale=$(regressions "$state/base.lock" "$state/all.lock")
          if [ -n "$stale" ]; then
            echo "<4>this host fetched heads older than origin already has: $stale"
            return 1
          fi

          if build "$state/all.lock"; then
            cp "$state/all.lock" "$state/good.lock"
          else
            build "$state/base.lock" || {
              echo "<3>origin does not build even without bumping any input"
              return 1
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
          fi

          if [ "''${#held[@]}" -gt 0 ]; then
            echo "<4>held back inputs whose bump does not build: ''${held[*]}"
          fi

          if same_lock "$state/base.lock" "$state/good.lock"; then
            echo "origin already has every head that builds"
            return 0
          fi

          cp "$state/good.lock" "$repo/flake.lock"
          git -C "$repo" commit -q -m "flake: bump inputs" -- flake.lock
          if git -C "$repo" push -q origin HEAD:main; then
            echo "pushed $(git -C "$repo" rev-parse --short HEAD)"
            return 0
          fi
          echo "<4>origin moved during attempt $attempt; bumping again from it"
        done
        return 1
      }

      adopt() {
        git -C "$work" fetch -q origin
        git -C "$work" show origin/main:flake.lock > "$state/origin.lock"
        nix flake lock "git+file://$work" \
          --reference-lock-file "$state/origin.lock" --output-lock-file "$state/work.lock"

        stale=$(regressions "$work/flake.lock" "$state/work.lock")
        if [ -n "$stale" ]; then
          echo "<4>the working clone has newer heads than origin, leaving its lock alone: $stale"
          return 1
        fi

        if same_lock "$state/work.lock" "$state/origin.lock"; then
          git -C "$work" checkout -q HEAD -- flake.lock
          if git -C "$work" merge -q --ff-only origin/main; then
            echo "fast-forwarded the working clone to $(git -C "$work" rev-parse --short HEAD)"
            return 0
          fi
        fi
        same_lock "$state/work.lock" "$work/flake.lock" || cp "$state/work.lock" "$work/flake.lock"
      }

      upgrade_home() {
        nix build --no-write-lock-file -o "$state/home" \
          "git+file://$work#homeConfigurations.\"max@${hostName}\".activationPackage"
        XDG_RUNTIME_DIR=/run/user/$(id -u) "$state/home/activate"
      }

      status=0
      publish || status=1
      adopt || status=1
      upgrade_home || status=1
      exit "$status"
    '';
  };
in
{
  config = lib.mkIf config.system.autoUpgrade.enable {
    environment.systemPackages = [ flakeSync ];

    systemd.services.flake-sync = {
      description = "Bump, push and adopt the shared flake lock, then upgrade home";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      before = [ "nixos-upgrade.service" ];
      environment.NIX_OBSERVER_PLAIN = "1";
      path = [ "/run/current-system/sw" ];
      serviceConfig = {
        Type = "oneshot";
        User = "max";
        StateDirectory = "flake-sync";
        ExecStart = lib.getExe flakeSync;
      };
    };

    systemd.timers.flake-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun 18:00";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };
  };
}

# Scheduled flake sync: bump and push the shared lock, adopt it on this host, upgrade home.

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
    { repo, host }:
    builtins.concatStringsSep "\n" [
      "git+file://''${repo}#nixosConfigurations.''${host}.config.system.build.toplevel"
      "git+file://''${repo}#homeConfigurations.\"max@''${host}\".activationPackage"
    ]
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

  changedInputs = pkgs.writeText "changed-inputs.jq" ''
    def locked($lock; $n): $lock.nodes[$lock.nodes.root.inputs[$n]].locked;
    $new[0].nodes.root.inputs | keys[]
    | select(locked($old[0]; .) != locked($new[0]; .))
  '';

  flakeSync = pkgs.writeShellApplication {
    name = "flake-sync";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.diffutils
      pkgs.git
      pkgs.gnugrep
      pkgs.jq
      pkgs.openssh
    ];
    text = ''
      state=''${STATE_DIRECTORY:-$HOME/.local/state/flake-sync}
      repo=$state/repo
      work=${flakePath}
      check=0
      [ "''${1:-}" = --check ] && check=1
      mkdir -p "$state"
      [ -d "$repo/.git" ] || git clone -q "$(git -C "$work" remote get-url origin)" "$repo"

      regressions() {
        jq -rn --slurpfile old "$1" --slurpfile new "$2" -f ${headRegressions}
      }

      same_lock() {
        cmp -s <(jq -S .nodes "$1") <(jq -S .nodes "$2")
      }

      changed() {
        jq -r --slurpfile old "$1" --slurpfile new "$2" -n -f ${changedInputs}
      }

      refresh_repo() {
        git -C "$repo" fetch -q origin
        git -C "$repo" reset -q --hard origin/main
        local out
        out=$(nix eval --impure --raw \
          --expr "import ${buildTargets} { repo = \"$repo\"; host = \"${hostName}\"; }") || return 1
        mapfile -t targets <<< "$out"
      }

      pin_overrides() {
        local out
        out=$(nix eval --raw --impure --expr "let p = import \"$repo/lib/pins.nix\" { root = \"$repo\"; host = \"${hostName}\"; }; in builtins.concatStringsSep \"\\n\" p.argv") || return 1
        pins=()
        [ -n "$out" ] && mapfile -t pins <<< "$out"
        ovr=("''${pins[@]}")
      }

      held_overrides() {
        [ -f "$state/held.json" ] || echo '{}' > "$state/held.json"
        mapfile -t heldArgs < <(jq -r 'to_entries[] | "--override-input", .key, .value' "$state/held.json")
        ovr=("''${pins[@]}" "''${heldArgs[@]}")
      }

      pinned_names() {
        for ((i = 1; i < ''${#pins[@]}; i += 3)); do
          printf '%s\n' "''${pins[$i]}"
        done
      }

      build() {
        rm -f "$state"/result*
        nix build --no-write-lock-file --reference-lock-file "$1" -o "$state/result" \
          "''${ovr[@]}" "''${targets[@]}"
      }

      bump() {
        local from=$1 to=$2
        shift 2
        nix flake update --refresh --flake "git+file://$repo" \
          --reference-lock-file "$from" --output-lock-file "$to" "$@"
      }

      publish() {
        for attempt in 1 2 3; do
          refresh_repo || return 1
          pin_overrides || return 1
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
              echo "<3>origin does not build for ${hostName} even without bumping any input"
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
            echo "origin already has every head that builds for ${hostName}"
            return 0
          fi

          if [ "$check" = 1 ]; then
            echo "check: the bumped lock builds for ${hostName}; not pushed"
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

      holdRef() {
        jq -r --arg n "$1" '
          .nodes[.nodes.root.inputs[$n]].locked
          | select(.type == "github")
          | "github:\(.owner)/\(.repo)/\(.rev)"
        ' "$state/head.lock"
      }

      write_held() {
        local obj='{}' name ref
        for name in "$@"; do
          ref=$(holdRef "$name")
          [ -n "$ref" ] || return 1
          obj=$(jq -c --arg k "$name" --arg v "$ref" '. + {($k): $v}' <<<"$obj")
        done
        printf '%s\n' "$obj" > "$state/held.json"
      }

      adopt_lock() {
        pin_overrides || return 1
        mapfile -t moved < <(changed "$state/head.lock" "$state/origin.lock")
        mapfile -t pinned < <(pinned_names)
        candidates=()
        for name in "''${moved[@]}"; do
          printf '%s\n' "''${pinned[@]}" | grep -qxF "$name" || candidates+=("$name")
        done

        echo '{}' > "$state/held.json"
        held_overrides
        if build "$state/origin.lock"; then
          return 0
        fi

        if ! write_held "''${candidates[@]}"; then
          echo "<3>the shared lock does not build for ${hostName}, and a changed input cannot be held back"
          return 1
        fi
        held_overrides
        if ! build "$state/origin.lock"; then
          echo "<3>the shared lock does not build for ${hostName}, even with every changed input held back"
          return 1
        fi

        kept=("''${candidates[@]}")
        for name in "''${candidates[@]}"; do
          trial=()
          for other in "''${kept[@]}"; do
            [ "$other" = "$name" ] || trial+=("$other")
          done
          write_held "''${trial[@]}"
          held_overrides
          if build "$state/origin.lock"; then
            kept=("''${trial[@]}")
          fi
        done
        write_held "''${kept[@]}"
        held_overrides
        echo "<4>held back on ${hostName}: ''${kept[*]}"
      }

      adopt() {
        refresh_repo || return 1
        cp "$repo/flake.lock" "$state/origin.lock"
        git -C "$work" fetch -q origin
        git -C "$work" show HEAD:flake.lock > "$state/head.lock"

        if ! adopt_lock; then
          return 1
        fi

        reason=""
        if [ -n "$(git -C "$work" status --porcelain)" ]; then
          reason="uncommitted changes"
        elif ! git -C "$work" merge-base --is-ancestor HEAD origin/main; then
          reason="commits not on origin"
        fi
        if [ -n "$reason" ]; then
          n=$(changed "$state/head.lock" "$state/origin.lock" | wc -l)
          if [ "$n" -gt 0 ]; then
            echo "lock behind origin by $n inputs; $reason, not adopted" > "$state/lag"
            echo "<4>lock behind origin by $n inputs; $reason, not adopted"
          else
            rm -f "$state/lag"
          fi
          return 0
        fi

        git -C "$work" merge -q --ff-only origin/main
        rm -f "$state/lag"
        echo "fast-forwarded the working clone to $(git -C "$work" rev-parse --short HEAD)"
        upgrade_home
      }

      upgrade_home() {
        nix build --no-write-lock-file -o "$state/home" "''${ovr[@]}" \
          "git+file://$work#homeConfigurations.\"max@${hostName}\".activationPackage"
        XDG_RUNTIME_DIR=/run/user/$(id -u) "$state/home/activate"
      }

      if [ "$check" = 1 ]; then
        publish
        exit
      fi

      status=0
      publish || status=1
      adopt || status=1
      exit "$status"
    '';
  };
in
{
  options.local.flakeSync.schedule = lib.mkOption {
    type = lib.types.str;
    default = "*-*-* 02:00:00";
    description = "systemd OnCalendar expression for the daily flake bump and push on this host.";
  };

  config = lib.mkIf config.system.autoUpgrade.enable {
    environment.systemPackages = [ flakeSync ];

    systemd.services.flake-sync = {
      description = "Bump and push the shared flake lock, adopt it locally, upgrade home";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment.NIX_OBSERVER_PLAIN = "1";
      path = [ "/run/current-system/sw" ];
      serviceConfig = {
        Type = "oneshot";
        User = "max";
        StateDirectory = "flake-sync";
        ExecStart = lib.getExe flakeSync;
        MemoryHigh = "3G";
        CPUWeight = "idle";
      };
    };

    systemd.timers.flake-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = config.local.flakeSync.schedule;
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };
  };
}

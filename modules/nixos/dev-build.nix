# dev-build: run a project's own incremental build here or on a remote builder.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  facts = import ../../hosts/facts.nix;
  selfName = config.networking.hostName;
  cfg = config.local.devBuild;

  builderFacts = facts.${cfg.builder} or { };
  nativeSystem = f: lib.head ((f.systems or [ ]) ++ [ null ]);
  selfSystem = nativeSystem (facts.${selfName} or { });

  canOffload =
    cfg.builder != selfName
    && (builderFacts.tailscale or "") != ""
    && selfSystem != null
    && selfSystem == nativeSystem builderFacts;

  excludes = pkgs.writeText "dev-build-excludes" ''
    .direnv/
    .stack-work/
    .venv/
    __pycache__/
    _build/
    dist-newstyle/
    node_modules/
    result
    result-*
    target/
    *.log
  '';

  devBuild = pkgs.writeShellApplication {
    name = "dev-build";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      git
      openssh
      rsync
    ];
    text = ''
      builder=${lib.escapeShellArg cfg.builder}
      builderAddress=${lib.escapeShellArg (builderFacts.tailscale or "")}
      threshold="''${DEV_BUILD_THRESHOLD:-${toString cfg.thresholdSeconds}}"
      remoteRoot=${lib.escapeShellArg cfg.remoteRoot}
      state="''${XDG_STATE_HOME:-$HOME/.local/state}/dev-build"

      where="''${DEV_BUILD_WHERE:-auto}"
      root=""
      action=run

      while true; do
        case "''${1:-}" in
          --local) where=local; shift ;;
          --remote) where=remote; shift ;;
          --root) root="''${2:?--root needs a directory}"; shift 2 ;;
          --status) action=status; shift ;;
          --forget) action=forget; shift ;;
          --) shift; break ;;
          -*) echo "dev-build: unknown option $1" >&2; exit 2 ;;
          *) break ;;
        esac
      done

      if [ -z "$root" ]; then
        root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
      fi
      project=$(basename "$root")
      record="$state/$project"
      mkdir -p "$record"

      case "$action" in
        status)
          if [ -z "$(find "$record" -type f -print -quit)" ]; then
            echo "no timings recorded for $project"
            exit 0
          fi
          for f in "$record"/*; do
            seconds=$(sed -n 1p "$f")
            if [ "$seconds" -ge "$threshold" ]; then
              verdict=$builder
            else
              verdict=here
            fi
            printf '%6ss  %-12s  %s\n' "$seconds" "$verdict" "$(sed -n 2p "$f")"
          done
          exit 0 ;;
        forget)
          rm -rf "$record"
          echo "dropped the timings for $project"
          exit 0 ;;
      esac

      if [ $# -eq 0 ]; then
        echo "usage: dev-build [--local|--remote] [--root DIR] [--status|--forget] CMD..." >&2
        exit 2
      fi

      printf -v command '%q ' "$@"
      timing="$record/$(printf '%s' "$command" | sha1sum | cut -d' ' -f1)"

      enter=("$@")
      if [ -e "$root/flake.nix" ]; then
        enter=(nix develop -c bash -c "$command")
      elif [ -e "$root/shell.nix" ] || [ -e "$root/default.nix" ]; then
        enter=(nix-shell --run "$command")
      fi

      offloadable=${if canOffload then "1" else "0"}

      if [ "$where" = auto ]; then
        where=local
        if [ "$offloadable" = 1 ] && [ -r "$timing" ] && [ "$(sed -n 1p "$timing")" -ge "$threshold" ]; then
          where=remote
        fi
      fi

      if [ "$where" = remote ] && [ "$offloadable" = 0 ]; then
        echo "dev-build: no builder to defer to; building here" >&2
        where=local
      fi

      reach() {
        ssh -o BatchMode=yes -o ConnectTimeout=10 \
          -o StrictHostKeyChecking=accept-new \
          "max@$builderAddress" true 2>/dev/null
      }

      if [ "$where" = remote ] && ! reach; then
        if command -v wake-peer >/dev/null 2>&1; then
          echo "dev-build: waking $builder" >&2
          wake-peer "$builder" >&2 || true
        fi
        if ! reach; then
          echo "dev-build: $builder is unreachable; building here" >&2
          where=local
        fi
      fi

      started=$SECONDS
      status=0

      if [ "$where" = local ]; then
        echo "dev-build: $project here" >&2
        (cd "$root" && exec "''${enter[@]}") || status=$?
        elapsed=$((SECONDS - started))
        printf '%s\n%s\n' "$elapsed" "$command" > "$timing"
        if [ "$elapsed" -ge "$threshold" ] && [ "$offloadable" = 1 ]; then
          echo "dev-build: that took ''${elapsed}s; the next one goes to $builder" >&2
        fi
        exit "$status"
      fi

      target="$remoteRoot/$project"
      echo "dev-build: $project on $builder ($target)" >&2

      rsync -a --compress --delete --mkpath \
        --exclude-from=${excludes} \
        -e "ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new" \
        "$root/" "max@$builderAddress:$target/"

      {
        printf 'set -euo pipefail\n'
        printf 'export NIX_OBSERVER_PLAIN=1\n'
        printf 'cd %q\n' "$target"
        printf '%q ' "''${enter[@]}"
        printf '\n'
      } | ssh -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new \
            "max@$builderAddress" bash -s || status=$?

      echo "dev-build: $project on $builder took $((SECONDS - started))s" >&2
      exit "$status"
    '';
  };
in
{
  options.local.devBuild = {
    builder = lib.mkOption {
      type = lib.types.str;
      default = "desktopnew";
      description = "Host that runs the incremental builds this one defers.";
    };

    thresholdSeconds = lib.mkOption {
      type = lib.types.int;
      default = 90;
      description = "A build recorded at or above this many seconds goes to the builder.";
    };

    remoteRoot = lib.mkOption {
      type = lib.types.str;
      default = "/home/max/offload";
      description = "Directory on the builder holding the synced worktrees.";
    };
  };

  config.environment.systemPackages = [
    devBuild
    pkgs.rsync
  ];
}

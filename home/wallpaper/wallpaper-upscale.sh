usage() {
  echo "usage: wallpaper-upscale [--local] [--force] [IMAGE...]" >&2
  exit 2
}

where=remote
force=0
inputs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --local) where=local ;;
    --force) force=1 ;;
    -*) usage ;;
    *) inputs+=("$1") ;;
  esac
  shift
done

exec 9> "${XDG_RUNTIME_DIR:-/tmp}/wallpaper-upscale.lock"
flock -n 9 || {
  echo "wallpaper-upscale: already running" >&2
  exit 1
}

mkdir -p "$ORIGINALS" "$POOL"

adopt() {
  local dest
  dest="$ORIGINALS/$(basename "$1")"
  [ "$(realpath "$1")" = "$(realpath -m "$dest")" ] && return
  if [ -e "$dest" ]; then
    cmp -s "$1" "$dest" || {
      echo "wallpaper-upscale: $dest already exists with different contents" >&2
      exit 1
    }
    rm "$1"
  else
    mv "$1" "$dest"
  fi
}

sources=()
if [ ${#inputs[@]} -gt 0 ]; then
  for f in "${inputs[@]}"; do
    [ -f "$f" ] || {
      echo "wallpaper-upscale: no such file $f" >&2
      exit 1
    }
    adopt "$f"
    sources+=("$ORIGINALS/$(basename "$f")")
  done
else
  for f in "$ORIGINALS"/*; do
    [ -f "$f" ] && sources+=("$f")
  done
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/in" "$work/out"

for f in "${sources[@]}"; do
  name=$(basename "$f")
  stem=${name%.*}
  if [ "$force" = 1 ] || [ -z "$(find "$POOL" -type f -name "$stem.png" -print -quit)" ]; then
    cp "$f" "$work/in/$name"
  fi
done

pending=$(find "$work/in" -type f | wc -l)
if [ "$pending" = 0 ]; then
  echo "wallpaper-upscale: nothing to do"
  exit 0
fi

upscale_local() {
  for f in "$work/in"/*; do
    name=$(basename "$f")
    echo "upscaling $name here"
    realesrgan-ncnn-vulkan -i "$f" -o "$work/out/${name%.*}.png" -n "$MODEL" -s 4 > /dev/null 2>&1
  done
}

upscale_remote() {
  local remote=offload/wallpaper-upscale
  wake-peer "$HOST" > /dev/null || return 1
  nix copy --to "ssh-ng://$HOST" "$REALESRGAN" || return 1
  ssh "$HOST" "rm -rf $remote && mkdir -p $remote/out" || return 1
  rsync -a "$work/in/" "$HOST:$remote/in/" || return 1
  ssh "$HOST" "cd $remote && for f in in/*; do n=\${f#in/}; echo \"upscaling \$n on $HOST\"; $REALESRGAN/bin/realesrgan-ncnn-vulkan -i \"\$f\" -o \"out/\${n%.*}.png\" -n $MODEL -s 4 > /dev/null 2>&1 || exit 1; done" || return 1
  rsync -a "$HOST:$remote/out/" "$work/out/" || return 1
  ssh "$HOST" "rm -rf $remote"
}

if [ "$where" = remote ]; then
  upscale_remote || {
    echo "wallpaper-upscale: $HOST unavailable, upscaling here" >&2
    rm -f "$work/out"/*
    upscale_local
  }
else
  upscale_local
fi

for f in "$work/out"/*.png; do
  stem=$(basename "$f" .png)
  previous=$(find "$POOL" -type f -name "$stem.*" -print -quit)
  dir=${previous:+$(dirname "$previous")}
  dir=${dir:-$POOL}
  magick "$f" -filter Lanczos -resize "$SIZE" "$dir/$stem.png.tmp"
  mv "$dir/$stem.png.tmp" "$dir/$stem.png"
  find "$POOL" -type f -name "$stem.*" ! -name "$stem.png" -delete
  echo "$dir/$stem.png"
done

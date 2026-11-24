image=$1
mount=$2
size=$3
owner=$4
group=$5

if ! mountpoint -q "$mount"; then
  if [ ! -e "$image" ]; then
    truncate -s "$size" "$image.new"
    mkfs.ext4 -q -m 0 "$image.new"
    mv "$image.new" "$image"
  fi
  mkdir -p "$mount"
  if [ -n "$(ls -A "$mount")" ]; then
    staging="$mount.migrate"
    mkdir -p "$staging"
    mount -o loop,nosuid,nodev,noexec "$image" "$staging"
    mkdir -p "$staging/data"
    cp -a "$mount/." "$staging/data/"
    umount "$staging"
    rmdir "$staging"
    find "$mount" -mindepth 1 -delete
  fi
  mount -o loop,nosuid,nodev,noexec "$image" "$mount"
fi

mkdir -p "$mount/data"
find "$mount" \( ! -user "$owner" -o ! -group "$group" \) -exec chown -h "$owner:$group" {} +
chmod 0750 "$mount"

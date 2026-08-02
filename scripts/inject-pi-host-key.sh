#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: inject-pi-host-key.sh <sd-image.img>}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
keydir="$repo/keys/generated"

loopdev=$(sudo losetup -f --show -P "$image")
trap 'sudo losetup -d "$loopdev"' EXIT

mnt=$(mktemp -d)
trap 'sudo umount "$mnt"; rmdir "$mnt"; sudo losetup -d "$loopdev"' EXIT

sudo mount "${loopdev}p2" "$mnt"
sudo install -D -m 0600 -o 0 -g 0 "$keydir/pi_ed25519" "$mnt/etc/ssh/ssh_host_ed25519_key"
sudo install -D -m 0644 -o 0 -g 0 "$keydir/pi_ed25519.pub" "$mnt/etc/ssh/ssh_host_ed25519_key.pub"

#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: flash-pi.sh [--yes] <image.img> <device>   e.g. flash-pi.sh result /dev/sda" >&2; exit 2; }

assume_yes=0
if [ "${1:-}" = "--yes" ]; then
  assume_yes=1
  shift
fi

image="${1:-}"
device="${2:-}"
[ -n "$image" ] && [ -n "$device" ] || usage

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
keydir="$repo/keys/generated"
key="$keydir/pi_ed25519"

[ -f "$image" ] || { echo "no image at $image" >&2; exit 1; }
[ -b "$device" ] || { echo "$device is not a block device" >&2; exit 1; }
[ -f "$key" ] || { echo "no host key at $key; run: just bootstrap pi" >&2; exit 1; }

# A host key that is not a sops recipient boots into a machine that cannot
# decrypt its wifi PSK or tailscale key, and is then unreachable.
recipient=$(nix run nixpkgs#ssh-to-age -- -i "$key.pub")
if ! grep -q "$recipient" "$repo/.sops.yaml"; then
  echo "host key $key.pub is not a recipient in .sops.yaml:" >&2
  echo "  $recipient" >&2
  echo "add it, run 'just rekey', and try again" >&2
  exit 1
fi
echo "host key matches .sops.yaml recipient $recipient"

echo "about to ERASE $device:"
lsblk -o NAME,SIZE,TRAN,MODEL,SERIAL "$device"
if [ "$assume_yes" -ne 1 ]; then
  read -r -p "type the device again to confirm: " confirm
  [ "$confirm" = "$device" ] || { echo "aborted" >&2; exit 1; }
fi

sudo dd if="$image" of="$device" bs=4M status=progress conv=fsync
sudo partprobe "$device"

mnt=$(mktemp -d)
cleanup() { sudo umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT

root=$(lsblk -lno NAME,LABEL "$device" | awk '$2 == "NIXOS_SD" { print "/dev/"$1; exit }')
[ -n "$root" ] || { echo "no NIXOS_SD partition on $device" >&2; exit 1; }

sudo mount "$root" "$mnt"
sudo install -D -m 0600 -o 0 -g 0 "$key" "$mnt/etc/ssh/ssh_host_ed25519_key"
sudo install -D -m 0644 -o 0 -g 0 "$key.pub" "$mnt/etc/ssh/ssh_host_ed25519_key.pub"
sync

echo "done: $device is ready to boot"

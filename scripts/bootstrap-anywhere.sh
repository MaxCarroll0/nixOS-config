#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: bootstrap-anywhere.sh <host> <target>   e.g. bootstrap-anywhere.sh server nixos@192.168.200.50" >&2
  exit 2
}

host="${1:-}"
target="${2:-}"
[ -n "$host" ] && [ -n "$target" ] || usage

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
key="$repo/keys/generated/${host}_ed25519"

[ -f "$key" ] || { echo "no host key at $key; run: just bootstrap $host" >&2; exit 1; }

if ! nix eval --accept-flake-config ".#nixosConfigurations.$host.config.disko.devices" >/dev/null 2>&1; then
  echo "$host declares no disko layout, so nixos-anywhere cannot partition it" >&2
  echo "add hosts/$host/disko.nix and import disko.nixosModules.disko" >&2
  exit 1
fi

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

extra=$(mktemp -d)
trap 'rm -rf "$extra"' EXIT
install -d -m 0755 "$extra/etc/ssh"
install -m 0600 "$key" "$extra/etc/ssh/ssh_host_ed25519_key"
install -m 0644 "$key.pub" "$extra/etc/ssh/ssh_host_ed25519_key.pub"

echo "about to ERASE the disks $host declares in disko, on $target"
read -r -p "type the hostname again to confirm: " confirm
[ "$confirm" = "$host" ] || { echo "aborted" >&2; exit 1; }

exec nix run github:nix-community/nixos-anywhere -- \
  --flake "$repo#$host" \
  --extra-files "$extra" \
  --target-host "$target"

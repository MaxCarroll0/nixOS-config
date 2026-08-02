#!/usr/bin/env bash
set -euo pipefail

hostname="${1:?usage: bootstrap-host.sh <hostname>}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
keydir="$repo/keys/generated"

mkdir -p "$keydir"
ssh-keygen -t ed25519 -f "$keydir/${hostname}_ed25519" -N "" -C "$hostname"

age_key=$(nix run nixpkgs#ssh-to-age -- -i "$keydir/${hostname}_ed25519.pub")

echo
echo "age key for $hostname: $age_key"
echo
echo "Add to .sops.yaml:"
echo "  keys: - &${hostname} ${age_key}"
echo "  creation_rules[0].key_groups[0].age: *${hostname}"
echo
echo "Then re-encrypt secrets:"
echo "  just rekey"

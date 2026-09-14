set -euo pipefail

key_url=https://workspaces-client-linux-public-key.s3-us-west-2.amazonaws.com/ADB332E7.asc
fingerprint=A6BF651A1797E7C4A825CA2FBEB35010ADB332E7
suite=noble

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$key_url" -o "$tmp/aws.asc"

if ! gpg --show-keys --with-colons "$tmp/aws.asc" | grep -q "^fpr:::::::::$fingerprint:"; then
  echo "workspaces-box: signing key does not match the pinned fingerprint" >&2
  exit 1
fi

sudo gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/amazon-workspaces.gpg <"$tmp/aws.asc"
echo "deb [arch=amd64] https://d3nt0h4h6pmmc4.cloudfront.net/ubuntu $suite main" |
  sudo tee /etc/apt/sources.list.d/amazon-workspaces.list >/dev/null

sudo apt-get update -qq
sudo apt-get install -y workspacesclient

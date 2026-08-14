default: check

# Build every deployed host and its home config without switching.
check:
    nix flake check --no-build
    nix build --no-link .#nixosConfigurations.laptop.config.system.build.toplevel
    nix build --no-link .#nixosConfigurations.desktop_new.config.system.build.toplevel
    nix build --no-link .#nixosConfigurations.pi.config.system.build.toplevel
    nix build --no-link '.#homeConfigurations."max@laptop".activationPackage'
    nix build --no-link '.#homeConfigurations."max@desktop_new".activationPackage'
    nix build --no-link '.#homeConfigurations."max@pi".activationPackage'

build host:
    nix build --no-link .#nixosConfigurations.{{host}}.config.system.build.toplevel

# Activate this host.
switch:
    rebuild switch

# Deploy a remote host with deploy-rs; reverts itself if it goes unreachable.
deploy host action="switch":
    rebuild --host {{host}} {{action}}

# Deploy without activating, to prove it builds and copies.
deploy-check host:
    rebuild --host {{host}} dry-activate

switch-home host="laptop":
    home-manager switch --flake .#max@{{host}}

update:
    nix flake update nixpkgs nixpkgs-unstable

# Print this machine's age recipient for .sops.yaml.
host-age-key:
    nix run nixpkgs#ssh-to-age -- -i /etc/ssh/ssh_host_ed25519_key.pub

edit-secrets:
    edit-secrets

# Re-encrypt after changing recipients in .sops.yaml.
rekey:
    nix run nixpkgs#sops -- updatekeys secrets/secrets.yaml

# Pre-generate a host's SSH identity before its first boot.
bootstrap host:
    scripts/bootstrap-host.sh {{host}}

# Bootable image for a pi host's USB SSD.
pi-image host="pi":
    nix build --print-out-paths .#packages.aarch64-linux.{{host}}-image

# Write an image to the SSD and inject that host's key.
flash-pi host image device:
    scripts/flash-pi.sh {{host}} {{image}} {{device}}

# Installer ISO trusting keys/max.pub, so nixos-anywhere can ssh straight in.
installer-iso:
    nix build --print-out-paths .#packages.x86_64-linux.installer-iso

# Install onto a machine booted from that ISO, planting its sops host key.
install host target:
    scripts/bootstrap-anywhere.sh {{host}} {{target}}

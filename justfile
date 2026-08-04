default: check

# Build both hosts and the home config without switching.
check:
    nix flake check --no-build
    nix build --no-link .#nixosConfigurations.laptop.config.system.build.toplevel
    nix build --no-link .#nixosConfigurations.desktop.config.system.build.toplevel
    nix build --no-link .#nixosConfigurations.pi.config.system.build.toplevel
    nix build --no-link '.#homeConfigurations."max@laptop".activationPackage'
    nix build --no-link '.#homeConfigurations."max@desktop".activationPackage'
    nix build --no-link '.#homeConfigurations."max@pi".activationPackage'

build host:
    nix build --no-link .#nixosConfigurations.{{host}}.config.system.build.toplevel

switch host:
    sudo nixos-rebuild switch --flake .#{{host}}

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

# Write the pi image to its USB SSD and inject the host key.
flash-pi image device:
    scripts/flash-pi.sh {{image}} {{device}}

Very WIP

Two hosts, `laptop` and `desktop`, from one flake.

```sh
sudo nixos-rebuild switch --flake .#laptop
home-manager switch --flake .#max@laptop
just check                              # build both hosts, no switch
```

## Secrets

All secrets live in `secrets/secrets.yaml` and are declared in
`modules/nixos/common.nix`. Home Manager reads the rendered `/run/secrets/*`
paths rather than decrypting anything itself.

Each host decrypts with its own SSH host key. Your personal age key is only
needed to *edit* secrets.

### Add a new machine as a recipient

On the new machine, once sshd has run at least once:

```sh
nix run nixpkgs#ssh-to-age -- -i /etc/ssh/ssh_host_ed25519_key.pub
```

Add the printed `age1...` to `.sops.yaml` under `keys:` and to the
`creation_rules` key group, then re-encrypt and commit:

```sh
nix run nixpkgs#sops -- updatekeys secrets/secrets.yaml
```

On a fresh install, generate the host key before the first switch:

```sh
sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
```

### Add a secret

```sh
nix run nixpkgs#sops -- secrets/secrets.yaml     # add the key
```

Then declare it in `modules/nixos/common.nix`, with `owner = "max"` if a user
process needs to read it.

### Set an account password

```sh
nix run nixpkgs#mkpasswd -- -m yescrypt          # paste the hash into sops
nix run nixpkgs#sops -- secrets/secrets.yaml
```

Add `local.users.sopsPasswords.<account> = "<secret-name>";`, switch, and confirm
`/run/secrets-for-users/<secret-name>` exists before setting
`users.mutableUsers = false`.

### Note

`nix.extraOptions` uses `!include`, not `readFile`. `readFile` resolves at
evaluation time, which needs `--impure` and copies the token into the
world-readable store. `!include` also tolerates the file being absent, which it
is until sops has run.

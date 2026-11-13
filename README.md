# nix

One flake, three NixOS hosts, each with a Home Manager profile.

| Host | Role |
|---|---|
| laptop | daily driver; sends builds to desktopnew; unlocks the NAS |
| desktopnew | remote builder and game VM host; suspends when idle |
| pi | always-on NAS, binary cache, monitoring, bookshelf catalogue |

Host addresses, MACs and architectures live in `hosts/facts.nix`.

## Deploying

Remote deploys roll back automatically if the host stops answering. Uncommitted changes can be
deployed: they go out as a snapshot commit, so every host always runs a revision that exists in
git and `deploy-status` shows what is running where.

| Command | Does |
|---|---|
| `rebuild [switch]` | build and activate this host |
| `rebuild --host NAME switch` | deploy NAME, with rollback |
| `rebuild --host NAME dry-activate` | show which units would restart |
| `deploy-status` | each host's revision relative to main, and any snapshot's changed files |

Source: `modules/nixos/deploy/`.

## Updates

Hosts update themselves daily and independently: `flake-sync` refreshes the inputs and pushes
a lock that builds, and `nixos-upgrade` activates `origin/main` overnight. An input that breaks
one host is held back on that host only; a host can pin an input for itself; a host running an
uncommitted snapshot is not upgraded over.

| Piece | Where |
|---|---|
| input refresh | `flake-sync`, `modules/nixos/flake-sync.nix` |
| held-back inputs | `/var/lib/flake-sync/held.json` on the host |
| per-host pins | `hosts/NAME/pins.nix` |
| upgrade timer and guard | `system.autoUpgrade` in `modules/nixos/common.nix` |

## Builds

desktopnew builds for the other hosts. It is only woken for builds worth the wake, and a build
proceeds locally if it cannot be reached. Project builds (cabal, dune, cargo, ...) can run there
too; the choice is made from the measured local build time, so small builds stay local. A
remote build's outputs stay on desktopnew and are fetched on demand; the builder keeps the
project's tree, artefacts and dev shell between runs and drops them only under disk pressure.

| Command | Does |
|---|---|
| `dev-build CMD` | run a project's own build here or on desktopnew |
| `dev-build ls`, `cat PATH`, `get PATH` | list, print or copy what the remote build wrote |
| `dev-build run [-p PORT] CMD` | run a command on desktopnew in the project, with PORT forwarded here |
| `dev-build status` | timings, where each command last ran, whether desktopnew still holds the tree |
| `vm-guard CMD` | run a heavy command on desktopnew without lagging the game VM |
| `nix-watch LOG` | one progress line a minute from a captured build log |

Source: `modules/nixos/build-client.nix`, `build-offload.py`, `dev-build.sh`, `vm-guard.nix`,
`nix-observer.nix`, `server/build-host.nix`.

## Disk

Space is reclaimed continuously rather than by one nightly sweep: the laptop collects in small
steps whenever free space drops under its target, including when files are added, and the
nightly clean only runs under pressure. Anything rederivable is fair game, ordered by cost:
quick project builds first, fetched sources last, toolchains and other slow builds kept while
space allows. The last cleanly booted generation is always kept. The performance tab of the
desktop shell shows the store by those tiers and the space taken by real files.

| Command | Does |
|---|---|
| `project-closure-retention` | report or evict project closures by tier against the budget |
| `project-scratch-clean` | report or remove recorded build artefacts, scratch dirs and caches |

Source: `modules/nixos/disk.nix` and the scripts beside it.

## Power

Each host is always on, suspends on a schedule, or suspends when idle. An SSH session,
including Tailscale SSH, keeps a host awake, so a leaked session keeps it up indefinitely.
Idle USB devices are powered down and come back on input. Power draw is estimated, as no host
has a wall meter.

| Command | Does |
|---|---|
| `wake-peer NAME` | wake NAME and wait until it answers |
| `power-report` | current estimated draw |

Source: `modules/nixos/power.nix`, `wake.nix`, `wake-endpoint.nix`, `monitoring/power-model.nix`.

## Network

All traffic goes through the Proton VPN or is blocked, except Tailscale and units marked to
bypass the tunnel (the nix daemon among them), so a dropped tunnel cuts egress rather than
leaking. No VPN config is stored; only the account credentials are. SSH is reachable over the
tailnet only. Public sites are published through a Cloudflare tunnel. A headless host that
loses the tailnet recovers by restarting networking, then rebooting.

| Command | Does |
|---|---|
| `vpn-switch` | change Proton server without dropping anything |
| `vpn-status` | tunnel state |

Source: `modules/nixos/vpn.nix`, `server/ssh.nix`, `server/web.nix`, `server/tailscale.nix`,
`wifi.nix`, `server/net-watchdog.nix`.

## NAS

The pi serves encrypted storage with parity, unlocked from the laptop. Every past state of the
data is retrievable (NILFS2 checkpoints), and streamed backups such as game worlds keep every
version at the cost of their differences. Accounts, shares and a nix binary cache are
declarative. Disks spin down when idle, so a first access can take a few seconds.

| Command | Does |
|---|---|
| `nas-at TIME` | mount the NAS as it was at TIME |
| `nilfs-reclaim` | free checkpoints nothing references |
| `stream-delta` | add or extract a version in the delta store |

Source: `modules/nixos/nas/`; design in `docs/nas.md`. `nas/enroll.nix` and `nas/web.nix`
exist but are not imported.

## Monitoring

Metrics from every host, with Grafana and alerting on the pi. Reading SMART does not wake a
parked disk. Crashes can be reconstructed from vitals written continuously to disk, and the last
cleanly booted generation is never garbage-collected.

Source: `modules/nixos/monitoring/`, `flight-recorder.nix`, `unclean-boot.nix`,
`last-good-boot.nix`; design in `docs/monitoring.md`.

## Desktop

Hyprland with an Emacs-style keymap, defined once and shared with Emacs; the caelestia shell
with local additions; Emacs from a literate config.

| Piece | Where |
|---|---|
| Hyprland config | `home/hypr/wm/`, `home/hyprland.nix` |
| keymap | `home/wm-keys.nix` |
| shell | `quickshell/caelestia/`, `home/caelestia.nix`, `home/patches/` |
| Emacs | `emacs/config.org`, `home/emacs.nix` |
| theme, wallpapers | `home/theme.nix`, `home/wallpaper/` |

## Secrets

Encrypted with sops to each host's SSH key; no extra key is needed on a host.

| Command | Does |
|---|---|
| `just edit-secrets` | open `secrets/secrets.yaml` |
| `just rekey` | re-encrypt after adding a recipient to `.sops.yaml` |

## Apps and checks

The bookshelf catalogue and the Satisfactory and Minecraft servers come from their own repos
as flake inputs.

| Command | Does |
|---|---|
| `just check` | build every host and home without switching |
| `just bump-bookshelf` | pin a new bookshelf revision |

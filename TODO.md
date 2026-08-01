# TODO

Turning the desktop into a dual-use workstation and remote server.

## Phase 0: merge and modularise

- [x] Lift `origin/desktop:hardware-configuration.nix` to `hosts/desktop/hardware.nix`
- [x] Split `configuration.nix` into `modules/nixos/{common,desktop-env,vpn}.nix`
- [x] Split `home.nix` into `home/{common,laptop,desktop}.nix`
- [x] Add `mkHost`/`mkHome` helpers and two hosts to `flake.nix`
- [x] Keep `nixosConfigurations.nixos` as a laptop alias until both machines switch
- [x] Fold desktop deltas into shared modules: `configurationLimit = 20`,
      `services.logind.settings.Login.HandleLidSwitch`, `services.xserver.xkb.layout = "gb"`
- [x] `git merge -s ours --allow-unrelated-histories origin/desktop`
- [ ] Delete the remote `desktop` branch once the desktop has switched
- [x] Replace deprecated `--update-input` in `system.autoUpgrade.flags`
- [x] Add `system.autoUpgrade.rebootWindow`
- [x] Swap `nix.settings.auto-optimise-store` for `nix.optimise.automatic`
- [ ] Add desktop host age recipient to `.sops.yaml` (`ssh-to-age` on its host key)
- [ ] Split secrets into `secrets/{common,desktop,laptop}.yaml`
- [ ] Drop the `nixos` alias and rename the laptop's hostname on its next switch

## Phase 1: remote shell

- [x] `modules/nixos/server/tailscale.nix`
- [x] Auth key optional: enrol once with `tailscale up` rather than storing one
- [x] `modules/nixos/server/ssh.nix`, hardened, no password auth, no root login
- [x] Port 22 only via `networking.firewall.interfaces."tailscale0"`, never globally
- [ ] Put the laptop's user key in `local.server.ssh.userKeys`

## Phase 2: remote builds

- [x] `modules/nixos/server/build-host.nix`: `nixremote` user, forced `nix-daemon --stdio`
- [x] `nix.settings.trusted-users`, `nrBuildUsers`, `auto-allocate-uids` + `cgroups`
- [x] `modules/nixos/build-client.nix`: `buildMachines` with `protocol = "ssh-ng"`
- [x] WoL wake wrapper, first build local and subsequent builds remote
- [x] Reuse Tailscale SSH identity for builder authentication
- [x] Verified Nix falls back to a local build when the builder is unreachable
      (logs `cannot build on`, exits 0), so the ProxyCommand approach stands
- [x] Verified `builder-wake` fails fast in ~2s instead of the TCP timeout, and
      that `wol -i` sends the packet
- [x] Fixed: `nc -w` also caps idle time, so it would have torn down a long
      build mid-flight. The probe owns the timeout, the data path has none.

## Phase 3: kill switch

- [x] Accept `oifname "tailscale0"` in `vpn-killswitch`
- [x] Separate nft table per bypassed unit, following the `nix-novpn` pattern so a
      missing cgroup cannot abort the killswitch transaction
- [x] Mark bypassed daemons `0xca6c` so they skip Proton rather than nesting in it
- [x] Syntax-check the generated tables with `nft -c`
- [ ] Reboot test with physical access available

## Phase 4: power

- [x] `modules/nixos/power.nix` with `local.power.*` options
- [x] `idle.optimise`: `amd_pstate=guided`, governor, powertop, SATA LPM
- [x] `idle.policy` enum: `always-on` / `scheduled` / `autosuspend`
- [x] `services.autosuspend` checks: Users, Load, LogindSessionsIdle,
      ActiveConnection, Processes
- [x] Assertion when public hosting is on and the policy is not `always-on`
- [x] Monitoring: node_exporter (rapl, hwmon, cpufreq, thermal_zone) + prometheus
- [x] `power-report` script over `/sys/class/powercap/*/energy_uj`
- [ ] Fill in `local.power.wakeOnLan.{interface,mac}` from `ip link`
- [ ] Measure idle draw under each policy and pick one
- [ ] Optional: metering smart plug for real wall draw
- [ ] Confirm `amd_pstate=guided` suits the specific CPU

## Phase 5: public hosting

- [x] `modules/nixos/server/web.nix`: `services.cloudflared.tunnels.*` from sops
- [x] nginx bound to `127.0.0.1`, never opened in the firewall
- [x] Static content as a Nix derivation, placeholder until the KB stack is picked
- [x] systemd hardening on the nginx unit
- [x] `systemd-analyze security nginx.service`: 1.5 to 1.1 after dropping all
      capabilities and restricting IPAddressAllow to localhost
- [x] Content is read-only: `limit_except GET HEAD`, 1k body cap, store-path roots
- [ ] Cloudflare Access policies for the gated hostnames (dashboard, not Nix)
- [ ] Replace the placeholder site derivation with the real content

The KB may end up a dynamic app served read-only. Isolation and write-path
decisions are deferred until it is picked; assume the strictest case until then.
When that happens, work through:

- [ ] Isolation: hardened unit / nspawn container / microvm. Prefer microvm for
      anything with a database, since nspawn root can escape to host root
- [ ] Block write and admin paths at nginx, not only at Cloudflare Access, so one
      misconfigured Access policy is not the only thing in the way
- [ ] Writable app state means backups, which static content did not need
- [ ] `client_max_body_size 1k` and `limit_except GET HEAD` will need relaxing if
      the app uses POST for search

## Out of band (not doable from Nix)

- [ ] Enable Wake-on-LAN in the desktop BIOS/UEFI; record NIC name and MAC
- [ ] Create the Tailscale auth key or enrol interactively
- [ ] Create the Cloudflare tunnel and Access policies; point DNS at Cloudflare

## Open questions

- [ ] Knowledge-base stack: which static generator (decided: read-only, no app)
- [ ] Whether a LAN device can relay WoL so remote wake works off-LAN

## Secrets and host keys

- [x] All secrets declared once at system level; HM reads /run/secrets paths
- [x] Laptop enables sshd so it gets a host key for sops
- [x] `local.users.sopsPasswords` maps accounts to sops hash secrets
- [x] Assertions: ssh lockout pair, WoL consistency, sshKey outside the store,
      web hostnames; warning on unverified builder host key
- [x] README secrets steps and justfile recipes
- [ ] Run `just host-age-key` on each machine, add to `.sops.yaml`, `just rekey`
- [ ] Add `max-password-hash` via `mkpasswd`, set `local.users.sopsPasswords`
- [ ] Confirm `/run/secrets-for-users/...` exists, then set `users.mutableUsers = false`
- [ ] Drop `sops.age.keyFile` from the hosts once host-key decryption is proven

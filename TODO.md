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
- [ ] Generate the passphrase-less `nixremote` key, root-owned
- [ ] Set `local.build.host.authorizedKeys` and flip `enable = true`
- [ ] Record the desktop's `publicHostKey`
- [ ] Verify Nix actually falls back to local when the builder is unreachable;
      if not, switch from ProxyCommand to a wrapper that waits

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
- [ ] Run `systemd-analyze security nginx.service` on the desktop and tighten
- [ ] Move the web stack into a `containers.web` with `privateNetwork = true`
- [ ] Cloudflare Access policies for the gated hostnames (dashboard, not Nix)
- [ ] Replace the placeholder site derivation with the real content

## Out of band (not doable from Nix)

- [ ] Enable Wake-on-LAN in the desktop BIOS/UEFI; record NIC name and MAC
- [ ] Create the Tailscale auth key or enrol interactively
- [ ] Create the Cloudflare tunnel and Access policies; point DNS at Cloudflare
- [ ] Generate the `nixremote` keypair

## Open questions

- [ ] Knowledge-base stack: static generator vs wiki app
- [ ] Whether a LAN device can relay WoL so remote wake works off-LAN

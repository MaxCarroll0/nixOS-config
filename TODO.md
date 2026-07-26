# TODO

Turning the desktop into a dual-use workstation and remote server.

## Phase 0: merge and modularise

- [ ] Lift `origin/desktop:hardware-configuration.nix` to `hosts/desktop/hardware.nix`
- [ ] Split `configuration.nix` into `modules/nixos/{common,desktop-env,vpn}.nix`
- [ ] Split `home.nix` into `home/{common,laptop,desktop}.nix`
- [ ] Add `mkHost`/`mkHome` helpers and two hosts to `flake.nix`
- [ ] Keep `nixosConfigurations.nixos` as a laptop alias until both machines switch
- [ ] Fold desktop deltas into shared modules: `configurationLimit = 20`, `services.logind.settings.Login.HandleLidSwitch`, `services.xserver.xkb.layout = "gb"`
- [ ] `git merge -s ours origin/desktop`, then delete the branch
- [ ] Replace deprecated `--update-input` in `system.autoUpgrade.flags`
- [ ] Add `system.autoUpgrade.rebootWindow`
- [ ] Swap `nix.settings.auto-optimise-store` for `nix.optimise.automatic`
- [ ] Add desktop host age recipient to `.sops.yaml` (`ssh-to-age` on its host key)
- [ ] Split secrets into `secrets/{common,desktop,laptop}.yaml`

## Phase 1: remote shell

- [ ] `modules/nixos/server/tailscale.nix`, `authKeyFile` from sops
- [ ] `modules/nixos/server/ssh.nix`, hardened, no password auth, no root login
- [ ] Port 22 only via `networking.firewall.interfaces."tailscale0"`, never globally

## Phase 2: remote builds

- [ ] `modules/nixos/server/build-host.nix`: `nixremote` user, forced `nix-daemon --stdio` command
- [ ] `nix.settings.trusted-users`, `nrBuildUsers`, `auto-allocate-uids` + `cgroups`
- [ ] `modules/nixos/build-client.nix`: `buildMachines` with `protocol = "ssh-ng"`
- [ ] Passphrase-less `nixremote` key, root-owned, from sops
- [ ] WoL wake wrapper, first build local and subsequent builds remote
- [ ] Verify Nix actually falls back to local when the builder is unreachable

## Phase 3: kill switch

- [ ] Accept `oifname "tailscale0"` in `vpn-killswitch`
- [ ] Separate nft table for tailscaled/cloudflared cgroup matches, following the
      existing `nix-novpn` pattern so a missing cgroup cannot abort the killswitch
- [ ] Mark both daemons `0xca6c` so they bypass Proton rather than nesting in it
- [ ] Reboot test with physical access available

## Phase 4: power

- [ ] `modules/nixos/power.nix` with `local.power.*` options
- [ ] `idle.optimise`: `amd_pstate=guided`, governor, powertop, SATA LPM, ASPM
- [ ] `idle.policy` enum: `always-on` / `scheduled` / `autosuspend`
- [ ] `services.autosuspend` checks: Users, Load, LogindSessionsIdle, ActiveConnection, Processes
- [ ] Assertion when public hosting is on and the policy is not `always-on`
- [ ] Monitoring: node_exporter (rapl, hwmon, cpufreq, thermal_zone) + prometheus + grafana on loopback
- [ ] `power-report` script over `/sys/class/powercap/*/energy_uj`
- [ ] Optional: metering smart plug for real wall draw

## Phase 5: public hosting

- [ ] `modules/nixos/server/web.nix`: `services.cloudflared.tunnels.*` from sops
- [ ] nginx bound to `127.0.0.1`, never opened in the firewall
- [ ] Static content as a Nix derivation, placeholder until the KB stack is picked
- [ ] Run the web stack in a `containers.web` with `privateNetwork = true`
- [ ] systemd hardening, check with `systemd-analyze security`
- [ ] Cloudflare Access policies for the gated hostnames (dashboard, not Nix)

## Out of band (not doable from Nix)

- [ ] Enable Wake-on-LAN in the desktop BIOS/UEFI; record NIC name and MAC
- [ ] Create the Tailscale auth key
- [ ] Create the Cloudflare tunnel and Access policies; point DNS at Cloudflare
- [ ] Generate the `nixremote` keypair; record the desktop `publicHostKey`

## Open questions

- [ ] Knowledge-base stack: static generator vs wiki app
- [ ] Whether a LAN device can relay WoL so remote wake works off-LAN

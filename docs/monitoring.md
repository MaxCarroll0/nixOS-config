# Monitoring: architecture, measurements and method

Why this exists: the pi is a 2 GB Pi 5 whose RAM can never be increased, and it is the
intended NAS host. The monitoring stack was consuming ~1.24 GB. This records what was
changed, what it actually saved, and how that was measured, so later changes can be judged
the same way.

## 1. How to measure a memory change here

Memory on the pi is genuinely volatile. Measured from `mem:used_ratio{instance="pi"}` over
7 days:

| stat | value | as RAM |
|---|---|---|
| stddev | 1.72 pp | ~35 MB |
| p5 to p95 | 68.5% to 73.5% | ~100 MB |
| min to max | 62.5% to 79.9% | ~350 MB |

Consequences, which govern every claim below:

- **A point-in-time before/after comparison is meaningless** inside a ~100 MB band. Compare
  medians over matched windows.
- **Architectural changes** are judged on the median of `MemAvailable` over a window of at
  least an hour. Detection floor ~35 MB.
- **Series-level changes are below that floor.** Judge them on `prometheus_tsdb_head_series`
  and `go_memstats_heap_inuse_bytes`, which respond immediately and are far less noisy.
- **Measure at a fixed offset after boot.** Prometheus memory climbs for hours as it re-touches
  mmap'd blocks, so an absolute number taken 15 minutes after a reboot is systematically low.
  The bias cancels only if both sides are sampled at the same point in the warm-up curve.
- **RSS overstates pressure.** cgroup accounting includes reclaimable page cache: the
  prometheus-longterm tier read 407 MB by cgroup against 221 MB RSS. `MemAvailable` is the
  ground truth for what the machine can actually use.

The instrument is `node_unit_memory_bytes`, a textfile collector reading systemd
`MemoryCurrent` per unit (`modules/nixos/monitoring/textfile.nix`). It is recorded as
`unit:memory_bytes` so it federates into the 2 year tier; without the `:` in the name it
would only survive the 3 hour hires retention, which is shorter than the gap between stages.

## 2. Baseline

Measured before any change, RSS and series held:

| Service | RSS | Series |
|---|---|---|
| grafana | 223 MB | |
| prometheus history (2y) | 221 MB | 1,860 |
| prometheus hires (3h, 1s) | 170 MB | 11,708 |
| prometheus archive (100y) | 143 MB | 532 |
| loki | 144 MB | 248 streams |
| alloy | 126 MB | |
| systemd-journald | 53 MB | |
| tempo | 47 MB | **0 traces, ever** |
| tailscaled | 68 MB | |
| node_exporter + pushgateway | 47 MB | |

Disk: root 43 GB of 109 GB used, of which `below` alone was 24 GB.

## 3. What changed, and what it saved

### Removed: Loki, Tempo and Alloy

Tempo had received **zero traces in its entire life**, so nothing emitted OTLP. Alloy existed
only to feed Loki and Tempo, so with both gone it had no remaining function and was deleted
rather than replaced.

| | median `MemAvailable` | p05 | p95 |
|---|---|---|---|
| before | 573.6 MB | 525.7 | 625.0 |
| after | **723.8 MB** | 678.0 | 756.8 |

**+150.2 MB**, and the distributions do not overlap (before-p95 625 < after-p05 678), so this
is a real change rather than noise.

Note the saving is roughly half what RSS predicted (~317 MB). Those services' RSS included
reclaimable page cache which the kernel already counted as available, so removing them frees
less than their RSS implied. This is exactly why the gate was written against `MemAvailable`.

`below` retention also dropped from 30 days to 1, taking `/var/log/below` from 24 GB to
7.6 GB.

### Pruned series and re-cadenced scrapes

`metric_relabel_configs` drop four of five `node_systemd_unit_state` states (only `failed`
carries information, and both consuming rules already filter on it), the `prometheus_http_*`
histogram buckets, `node_cpu_guest_seconds_total`, `node_cpu_scaling_governor` and
`node_scrape_collector_duration_seconds`. Nothing in `rules.nix` or `dashboards.nix`
referenced any of them.

| metric | before | after |
|---|---|---|
| hires head series | 12,014 | **8,779** (−3,235) |
| `go_memstats_heap_inuse_bytes` | 144 MB | **79 MB** (−45%) |
| `node_systemd_unit_state` | 2,955 | 605 |

The series target was −3,500, so this **fell 265 short**. Part of the shortfall is the
instrument itself: `unit:memory_bytes` and its 1m rollup add 244 series. The heap result is
the meaningful one, since that is RAM the pi actually gets back.

**Remote hosts must be deployed individually.** They push via vmagent remote-write, which
bypasses the pi's scrape-time `metric_relabel_configs` entirely, so filtering has to happen
at each source.

### Replaced: three Prometheus tiers with VictoriaMetrics

One `victoriametrics` at 7 day retention scraping directly, a `victoriametrics-history`
instance holding 1h rollups, and `vmalert` evaluating the `rules.nix` groups against both.

| | before | after |
|---|---|---|
| metrics store | 940 MB (hires 106, longterm 410, archive 424) | **272 MB** |
| | | victoriametrics 214, history 23, vmalert 35 |
| active series | 14,100 | 5,638 |

**−668 MB**, the largest single saving of the whole exercise. Grafana at ~306 MB is now the
biggest consumer.

Verification that matters more than the memory number: `count(mem:used_ratio)` must return a
non-empty result. vmalert evaluates the recording rules that every dashboard is built on, so
if it is not running them the panels are blank while the deploy still reports success. Check
it explicitly after any change to the rule groups or the vmalert unit.

Two failures on the way, both of which rolled back cleanly:

- **`-retentionPeriod` under one day is rejected** (see below), so the hires tier moved from
  3h to 7d.
- **An orphaned unit failed activation with exit 4.** `hosts/pi/default.nix` still set
  `local.monitoring.backfill`, listed the service in `bulk`, and — the actual trigger — set
  `systemd.timers.prometheus-rule-backfill.timerConfig.OnBootSec`, which *defines* the timer.
  With the implementation removed, activation tried to restart a timer whose service no longer
  existed. Removing an implementation is not enough: grep for every reference, including
  per-host `systemd.services.*`/`systemd.timers.*` overrides, which keep a unit alive on their
  own.

### Capped: Grafana

`GOMEMLIMIT = 224MiB` plus `MemoryHigh = 288M`. Both are **soft**: Go collects more aggressively
as it approaches the limit, and the cgroup applies reclaim pressure. Neither OOM-kills, which is
deliberate — `MemoryMax` would kill the only UI onto the whole stack.

Grafana had grown to ~306 MB unbounded, making it the largest consumer once the metrics store
dropped to 272 MB. Treat this as a ceiling rather than a measured saving until a warm reading is
taken: a number sampled minutes after a restart is systematically low, and the 306 MB it is
compared against was taken after long uptime.

The dead `exploretraces` and `lokiexplore` plugins were dropped when Loki and Tempo were removed;
only `grafana-metricsdrilldown-app` remains.

**Renaming a provisioned datasource is a breaking change.** Grafana matches provisioned
datasources by *name*, not uid, so renaming while keeping the uid makes it try to insert a row
whose uid already exists, and it fails to start:

```
Datasource provisioning error: data source with the same uid already exists
```

The fix is to list the **old** names in `deleteDatasources` so they are removed before the new
ones are inserted. Keep the uids identical — dashboards reference datasources by uid, so a rename
is then invisible to them. This caused a ~50 minute outage. Two further traps it exposed:

- After repeated failures systemd hits the start limit and gives up, so a corrected config will
  not start on its own: `systemctl reset-failed grafana` is required first.
- **A generation number is not proof a change is live.** The profile read `system-95-link` while
  the host was still running the previous provisioning. Verify the artefact itself — here, the
  `grafana-provisioning` store path in the journal — not just the generation.

### Scrape cadence by data class

| Class | Interval | Examples |
|---|---|---|
| live | 1 s | CPU, load, PSI pressure, power, thermal, memory, network |
| slow | 60 s | systemd `failed`, tailscale peers, capacity |
| inventory | 1 h | filesystem, SMART, drive temperatures, static config |

**Standing principle: no exporter may be the reason a disk wakes.** Scraping observes
activity, it must never cause it. The smartctl collector already uses `-n standby` throughout
and runs every 5 minutes, so it never wakes a sleeping disk.

## 4. Logs and deep exploration: local, not central

Central logging was removed. Exploration is delegated to on-demand CLI against each host,
which costs the pi nothing:

| Need | Aggregate (Grafana) | Drilldown |
|---|---|---|
| nix builds | count, duration, failure rate, alerts | `journalctl -t nix-observer-summary` over ssh |
| systemd services | failed-unit count | `systemctl -H max@<host>` (works natively) |
| load pressure, thrashing | PSI, refault, swap, faults | `below replay` on the host |

`nix-observer` already writes structured JSON to each host's journal, so **no build history was
lost** by removing Loki: it was only aggregating what the journal already held. Build outcomes
are re-exported as metrics by a textfile collector so Grafana keeps build dashboards and
failure alerts. Grafana's alert state history moved from the Loki backend to `annotations`.

Note `journalctl -H` is not compiled into this systemd; use `ssh <host> journalctl`.

## 5. Fixed along the way

- `grafana-alert-duration-tracker` was failing every minute: an empty state file was passed
  straight to `jq --argjson`. It now validates with `jq -e` first, and uses `if` rather than
  `&&` so a missing file cannot trip `set -e`.
- `node_sensor_name` emitted duplicate label sets, failing a scrape every second. Sibling
  `drivetemp` chips produce byte-identical lines, so `sort -u` deduplicates without loss; the
  per-drive distinction is already carried by `node_sensor_chip`.

## 6. Still to do

- **VictoriaMetrics migration.** Three Prometheus processes hold 14,100 series for 534 MB
  (775 MB by cgroup accounting). Target: one `live` instance at 7 day retention plus a
  socket-activated `history` instance holding 1h rollups forever, driven by vmalert. Estimated
  ~380 MB. OSS VictoriaMetrics cannot downsample or hold two retentions in one process, so two
  instances are unavoidable.

  **VictoriaMetrics refuses `-retentionPeriod` below one day**, so the hires tier cannot keep
  Prometheus's 3 hour setting: it exits 255 at startup with `-retentionPeriod cannot be smaller
  than a day`. The tier is therefore 7 days. This costs disk, not RAM — VictoriaMetrics memory
  scales with active series, not retention.

  Validate both before deploying, since a bad value only fails at runtime and takes a rollback
  with it:

  ```bash
  nix eval --raw .#nixosConfigurations.pi.config.systemd.services.victoriametrics.serviceConfig.ExecStart
  nix-shell -p victoriametrics --run 'victoria-metrics -promscrape.config=PATH -promscrape.config.dryRun'
  ```
- **Grafana trim.** `GOMEMLIMIT` and dropping the now-dead `exploretraces` plugin.

## Electricity accounting audit (2026-09-15)

Energy and cost now use recorded one-second power samples summed into disjoint
minute buckets, retained in the history store. A watt sampled for one second is
one joule; kWh is the sum of those joules divided by 3,600,000. A minute containing
only 30 samples at 100 W contributes 3,000 J, regardless of whether the dashboard
shows one day or seven days. Neither missing history nor the age of a newly
started host enlarges that total. Costs apply the dashboard's p/kWh tariff;
standing charges are outside this per-device calculation.

The previous deployed query multiplied an average of available samples by all
168 hours in a week. Desktopnew's approximately 77 W average therefore appeared
as £2.70, despite only about 80 minutes of stored readings at the initial check.
The intermediate repository formula also extrapolated: dividing by observed
`host:up` sample count and multiplying by the requested duration still enlarged
incomplete history.

`pc:power_watts` is instantaneous mains draw: a fresh meter takes precedence,
otherwise it is estimated from the component model. `pc:power_dc_watts` is device
load before the AC supply, including use on battery. `pc:usage_power_watts` is the
electricity attributed to that use and feeds the energy and cost panels:

- Direct mains use includes the supply's conversion loss.
- Battery use accrues the electricity needed to replenish it, using 90% charging
  efficiency plus the estimated AC-supply efficiency.
- Charging energy goes into the battery, so it is excluded from the usage total
  at charge time. It is accounted for when the battery is used. A mains reading
  during charging is apportioned by the device and charging DC loads.

This is consumption-based accounting, not a time-of-day electricity bill. It
cannot reproduce changing tariffs, batteries charged elsewhere, or charging loss
outside the assumed efficiency. The selected tariff applies to the whole range.

### Model findings and corrections

| Area | Finding and action |
|---|---|
| Laptop platform | PSYS was reduced by CPU power, then CPU **and** display, board, storage and fans were added again. A whole-platform reading now replaces overlapping component estimates. Battery discharge power is preferred while unplugged. |
| CPU domains | The desktop's zenpower `SVI2_P_Core` and `SVI2_P_SoC` are separate rails and remain additive. RAPL package is an alternative, never added to zenpower; duplicate MMIO package reporting is excluded. Implausible package rates are rejected instead of becoming a fabricated 400 W. |
| PSU loss | Efficiency already includes conversion loss. The old additional idle loss inflated every active reading; idle loss is now a floor on conversion loss. |
| Freshness | Raw node scrape freshness gates estimates, preventing the server's two-hour lookback from perpetuating a running-host model after telemetry stops. A missing CPU/platform reading cannot produce a board-only total. Meter freshness is checked separately. |
| Meter | A meter now overrides the model for mains draw. The residual still compares the meter with the independent model. |
| Drives | SSD/NVMe accounting no longer depends on ATA standby probing succeeding. A known disk retains its idle term while its I/O rate is warming up. Rotating disks use reported standby state, not zero I/O as a proxy. Disk busy fractions are bounded to 0–1. |
| Fans | Speed ratios are bounded to 0–1 before the power law; negative tachometer values cannot produce invalid fractional powers. |
| Pi | The VDD_CORE rail and the remaining PMIC rails are disjoint. DDR is already within those rails, and the Pi's separate RAM estimate is disabled. PMIC loss and AC-supply loss are different conversion stages. |
| Graph stacking | The combined live model line was passed through an instance join after aggregation had removed its instance label. It now smooths and gates each host before summing. Component bands describe the model, which can differ from a wall meter. |

The desktop GPU identifies as AMD `1002:67df` (Polaris), reporting PPT/chip power.
Its existing `1.13 × reported watts + 7 W` allowance for unreported board loads is
retained as an **uncalibrated estimate**, not a measured board-power value. The
separate GPU fan term belongs to this chip-power model. An APU or a GPU reporting
total board power needs different boundaries; the same extra terms must not be
applied blindly. The kernel documents that AMD APU power includes its CPU:
[AMDGPU power interfaces](https://docs.kernel.org/gpu/amdgpu/thermal.html).

The desktop's board (12 W), peripherals (2 W), RAM coefficients, fan curves and
supply curve remain hardware estimates. A same-window check found zenpower near
27.8 W versus RAPL near 36.6 W, so neither can establish actual wall draw by
itself. The Pi's 1.8 W peripheral allowance assumes the unmonitored controller
load; its PMIC readings do not include direct 5 V and external 12 V loads.
The configured 60 W supply curve assumes those loads share the modeled supply.
Separate disk-enclosure power supplies require separate conversion losses.
See [Pi power telemetry](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html).

No wall-meter calibration was supplied during this audit. Sleep, soft-off and
unobserved intervals therefore remain **unknown**, not measured zero. The energy
coverage panel exposes the recorded fraction of the selected period. Short
telemetry gaps, unmeasured disk spin-up transients, drive power-saving states,
and coarse component estimates limit accuracy. The power model cannot honestly
be presented as a revenue-grade electricity meter.

Minute energy buckets are written directly to the history store by the energy
vmalert instance; they are never averaged into hourly power rollups. Results
normally lag by up to two minutes. The energy writer reads a minute behind real
time so the primary recording rules have finished. An hourly repair replays the
retained power samples after delays or downtime. Both stores deduplicate identical
millisecond timestamps, so replay and overlapping archive copies cannot count a
sample twice. Existing averaged historical power cannot be
converted back into exact energy; retained raw telemetry is needed for repair.
Rule semantics are covered by `tests/monitoring-power.py`, which accepts the
JSON evaluation of `rules.nix` and a promtool executable.

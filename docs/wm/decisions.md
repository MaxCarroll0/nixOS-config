# Rejected alternatives

Why this exists: several of these options are attractive on first look and will be proposed
again. This records what was rejected, the actual reason, and what would change the verdict.

## 1. Strict frames-only (every buffer its own Hyprland window, Emacs never splits)

Maximum uniformity: the WM becomes the single source of truth for layout, so blur, animations
and the ace alphabet apply evenly to a flat namespace.

**Rejected** because org-mode, magit, ediff and gnus all assume they may split a window at
will, and taming each package costs more than the uniformity returns. `frames-only-mode`, the
canonical implementation, concedes the same point by keeping `*Completions*` in an Emacs window
by default. pgtk frame creation at ~50-100 ms also makes every transient buffer perceptibly
slower.

Chosen instead: hybrid, one buffer per frame by default with at most a 2-way split for
genuinely paired buffers.

**Would change the verdict:** if the tier-2 child-frame policy turns out to absorb almost every
transient buffer, the remaining pressure to split may be small enough that strict becomes
viable.

## 2. `dawsers/hyprscroller` instead of the core scrolling layout

Superseded in part: the alternative was originally framed as the *official plugin*
`hyprscrolling`. On checking the pinned Hyprland 0.56.0 binary, **the scrolling layout is core**
(see [README.md](README.md) §4), so there is no plugin on either side of this comparison and the
robustness argument below is stronger than when it was written.

Genuinely richer: row and column modes, width *and* height presets, pinning, per-monitor
options, and built-in `scroller:jump` overview labels plus marks and trailmarks — which look
like three of this project's components for free.

**Rejected** on two independent grounds.

Robustness: it targets Hyprland 0.48.1 as its primary version while this config tracks git
trunk, placing it on the author's feature-frozen tier. The author states Hyprland "was starting
to limit what I could add through a plugin" with "too many API changes going on upstream", and
has migrated to a forked compositor. A `nix flake update` could break the layout.

More decisively, the free features do not meet the requirements. `scroller:jump` labels
Hyprland windows and **cannot label Emacs internal splits**, so it can only ever be half of the
unified ace. Its marks and trailmarks are a **second, parallel ring**, when the entire point is
that windows join *the* Emacs mark ring and `C-x C-SPC` pops either kind. Adopting it would mean
building the Emacs halves anyway and then owning two overlapping systems.

The core scrolling layout has no plugin to break. The bridge talks to Hyprland's IPC socket
rather than to the layout, so this decision stays cheap to revisit.

**Would change the verdict:** height presets or pinning proving essential and not scriptable.

## 3. Chromium CDP debug port instead of a native-messaging extension

Much less work: `/json/list` and `/json/activate/<id>` are plain HTTP GETs, so tab control is
~40 lines of elisp with no JavaScript at all, and full page-content access comes free for
capturing pages into org-roam.

**Rejected** on three grounds.

Capability mismatch: the port only supports polling. Tab management wants **push** — a
`consult-buffer` source that is always correct without a refresh is the difference between a
novelty and something that feels like buffers. An extension gets tab created/closed/moved events
for free.

Security: the port is an unauthenticated localhost interface to the whole browser session —
cookies, logged-in sessions, everything. There is active 2026 exploitation literature on exactly
this.

Upstream direction: Chrome 136+ already refuses `--remote-debugging-port` against the default
profile, requiring a dedicated `--user-data-dir`, and each release tightens further. Building on
it is a treadmill.

**Would change the verdict:** nothing likely. If deep page-content access is later needed, scope
`chrome.debugger` inside the same extension, under Chrome's permission model, rather than
opening a port.

## 4. Focus follows mouse

Standard tiling-WM behaviour and faster for mouse-adjacent work.

**Rejected** because it decouples focus from intent, and this design has a component that
depends on focus *being* intent: the unified mark ring. Mouse-originated focus changes would
flood the ring and make popping unpredictable, so they would have to be filtered out — at which
point the mouse is no longer really driving focus. Emacs also has exactly one point and no
mouse-focus concept, so an Emacs frame stealing point because the cursor drifted is a direct
contradiction of the model.

`follow_mouse = 0`. Click and keyboard only.

## 5. vterm instead of eat

~1.5x faster than byte-compiled eat, because libvterm is C.

**Rejected** because the speed only matters for megabyte bursts, and tier 3 (ghostty, a real
Hyprland window) exists precisely to absorb those. Within tier 2's remit — interactive TUIs with
bounded output — eat is comfortably fast enough at ~3x `term`, is pure elisp so no native module
enters the Emacs closure, and integrates natively with eshell's visual-command dispatch via
`eat-eshell-mode`.

**Would change the verdict:** finding a genuinely interactive TUI that eat cannot keep up with
and that ghostty is a bad fit for.

## 6. EXWM (Emacs as the window manager)

The maximally Emacs-native answer, and it makes every window a buffer by construction.

**Rejected** because it forfeits the entire reason for using a compositor: no blur, no
animations, no layer-shell bars, no scrolling layout, weak multi-monitor, and Wayland support
that does not exist in the form needed here. It also puts the desktop inside the editor's
single-threaded event loop, which is the exact failure mode README §5 is built to prevent — a
wedged Emacs would take the whole session with it, with no fallback possible.

## 7. Auto-restarting the Emacs daemon on hang

Self-healing while away from the machine.

**Rejected** because a hang is not reliably distinguishable from a legitimately long
computation, and an unattended restart would sometimes discard state `desktop-save-mode` had not
yet checkpointed. Notify after 3 consecutive failed pings and name the restart bind; let the
human decide.

## 8. Free-form column widths only (no presets)

**Not rejected, but not sufficient alone.** Both are configured. Presets exist because a layout
reproducible by keystroke survives docking and undocking, whereas a dragged layout cannot be
recreated on a different monitor geometry. Free-form resize stays available for one-off cases.

## 9. Shared numeric workspaces / project-named workspaces

The workspace model is **deferred**, not decided. Default is per-monitor numeric, because it is
robust to the laptop docking and undocking and because `SUPER+N` then always means the same
physical place.

Project-named workspaces remain the interesting alternative, and per-project environment
isolation (Phase 2 step 13) is deliberately built so that adopting them later does not require
redesigning it. Duplicating project identity in both Emacs and the WM is the risk to avoid;
`project.el` and `tab-bar` already hold it.

## 10. Stylix, or any build-time-only theming

Stylix would deliver most of the colour work immediately: base16 schemes, very broad app
coverage, wallpaper-derived palettes, all wired up.

**Rejected** because it themes at *build* time. Every scheme change becomes a rebuild, which
makes runtime switching slow and makes continuous theming — driven by time of day, screen
brightness or wallpaper — impossible rather than merely unimplemented. Since continuous
switching is a stated goal, the palette must be a runtime artefact.

Chosen instead: a `palette.json` contract plus a `theme-apply` script using each app's live
reconfiguration path (`hyprctl keyword`, eww reload, `load-theme`, ghostty reload). See
[theme.md](theme.md) §1. Nix still generates the scheme data and the generators; it just does
not bake the active palette into config files.

**Partially adopted:** `base16-schemes` as scheme data and `matugen` for wallpaper-derived
palettes are worth using as *producers* feeding the same contract. The rejection is of
build-time application, not of the ecosystem.

**Would change the verdict:** giving up on continuous theming. If discrete switching at rebuild
time were acceptable, stylix would be the better trade.

## 11. Home Manager's `settings` for Hyprland configuration

The natural approach: declare everything in `wayland.windowManager.hyprland.settings` and let
Home Manager render it.

**Rejected** because of version skew that fails silently. Home Manager's Lua generator targets
the Hyprland it ships stubs for (0.55.4) and emits `hl.animations({…})` / `hl.general({…})`,
neither of which exists in the pinned 0.56.0. The result is not a build error: the compositor
starts, reports one `configerrors` line, and runs on stock defaults. Its hyprlang generator is
worse — 0.56 parses configs as Lua, so a hyprlang file produces a Lua syntax error and applies
nothing at all.

Chosen instead: `settings = { }`, and this repo generates the Lua itself into `extraConfig`
using `hl.config` with dotted flat keys, plus `hl.curve`, `hl.animation` and `hl.window_rule`.
See [README.md](README.md) §3a for the full API. This removes the skew dependency permanently —
the config is now coupled to Hyprland's Lua API, which we test against directly, rather than to
Home Manager's idea of it.

**Cost:** `settings` no longer type-checks the option names. Mitigated by the fact that
`hl.config` *does* reject unknown keys at load (`misc.vfr` was caught this way), which
`hl.window_rule` notably does not.

**Would change the verdict:** Home Manager's hyprland module gaining 0.56 support, at which
point `settings` becomes the better home for the plain key/value part.

## 12. `lib.generators.toPretty` for generating elisp

Used initially to serialise the keymap description into `wm-keys.el`, on the assumption that a
generic pretty-printer would produce something Lisp-shaped.

**Rejected because it emits Nix syntax.** The generated file began
`'{ root = { ace = { desc = "…" …` and failed to load with "Too many arguments". It had been
generated for some time and never loaded by anything, so nothing surfaced the breakage.

Chosen instead: a small explicit `toElisp` in `home/wm-keys.nix` mapping bools to `t`/`nil`,
attrsets to dotted alists and lists to Lisp lists.

**The lesson, not the fix:** a generated artefact with no consumer is untested by construction.
Anything generated should be loaded by its real consumer in a test, not merely built.

## 13. Assuming `systemctl --user restart emacs.service` works

`emacs/config.org` describes the daemon as "systemd-managed" in three places and offers
`my/restart-emacs-from-profile`, which runs `systemctl --user restart emacs.service`. The
Hyprland escape hatch `SUPER+CTRL+ALT+R` was built on the same assumption.

**The unit did not exist.** `services.emacs` was enabled nowhere in this configuration, and no
`emacs.service` appeared in the Home Manager generation. A unit was nonetheless *running*, left
loaded in the user systemd manager from an older generation whose file had since been removed —
so `systemctl restart` appeared to work while the unit remained in memory, and became
unrecoverable the moment the daemon actually stopped.

Fixed by enabling `services.emacs` in `home/emacs.nix`, which produces
`ExecStart = bash -l -c "…/emacs --fg-daemon"` — identical to what was already running. The
config now matches what it documents about itself.

**The lesson:** a service that responds to `systemctl restart` is not proof that a unit file
exists. `systemctl --user cat <unit>` is the check; `is-active` is not.

## 14. Omitting the monitor rule, and the `output` wildcard

The Lua rewrite dropped the old hyprlang `monitor = ,preferred,auto,1` line. Without it an
output defaults to **scale 2.0**, halving the logical resolution: fonts render at twice their
size and `gaps_out = 40` eats 12% of a 640-wide logical screen instead of 3% of 1280. Both of
those read as "the theme is wrong" when the theme is fine.

Restored as `hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })`.

Two things worth knowing about that call:

- **`output = ""` is the catch-all.** `output = "*"` is not a wildcard — it produces *zero*
  monitors, `hyprctl monitors all` included, which is a far worse failure than the bug it was
  meant to fix.
- **Monitor rules apply when an output is created, not on reload.** A `hyprctl reload` will not
  re-scale an existing output, so testing a monitor rule by reloading gives a false negative,
  and a previously applied scale sticks and gives a false positive. Only a cold start is
  evidence either way. Both mistakes were made here before the cold-start test settled it.

`misc.background_color` is set from the `bg` role for the same reason: with no wallpaper daemon
in Phase 1, an unset background renders as nothing rather than as the theme.

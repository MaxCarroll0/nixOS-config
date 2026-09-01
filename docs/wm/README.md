# Emacs-native Hyprland desktop: architecture

Why this exists: KDE/Plasma is being replaced by Hyprland, and the replacement is not a
straight swap. The goal is a desktop where Emacs idioms — directional movement, ace jumping,
one kill-ring, one mark-ring — are the native interaction model *at the window manager level*,
while keeping what a compositor gives you that Emacs cannot: tiling, blur, animations,
multi-monitor, screenshare. This document records the architecture and, more importantly, the
constraints that forced it, so later changes can be judged against the same reasoning.

**Status: Phase 0 (design). No Hyprland configuration exists yet.** `home/hyprland.nix` is an
empty `settings = {}` and Plasma is still doing the real work.

Companion documents: [keys.md](keys.md) is the keymap spec, [theme.md](theme.md) the visual
spec, [decisions.md](decisions.md) the rejected alternatives and why.

## 1. The governing split

> Emacs is the policy engine. Hyprland is the mechanism.

Emacs is the only party that knows a buffer is `*magit-diff*` rather than `config.org`, knows
where point is, and owns the kill-ring and mark-ring. Hyprland is the only party that can tile,
blur, span monitors and exclude a surface from a screen capture. Every decision below is an
application of one rule: **put each policy on the side that can actually evaluate it, and let
the other side provide only mechanism.**

This is not EXWM (Emacs replacing the WM) and not a plain tiling setup (the WM ignoring Emacs).

## 2. Two tiers, and why the line is mechanical rather than aesthetic

**Tier 1 — WM-managed.** Buffers that are *documents*: files, project buffers, eshell, magit
status, the browser, terminals. One buffer per Emacs frame; Hyprland tiles the frames.

**Tier 2 — Emacs-only, never the WM.** UI anchored to a *point inside a buffer*: eldoc, corfu,
flymake-at-point, signature help, which-key, transient menus, the minibuffer. Emacs child
frames.

The line is forced, not chosen. Under pgtk/Wayland **Emacs cannot position its own top-level
frames** — `set-frame-position` is a no-op, because Wayland gives clients no say in placement.
So "float this frame near the cursor" is impossible as a real window, at any level of effort.
Child frames, which Emacs draws itself inside the parent surface, are the only mechanism that
exists. Corfu already works this way in the current config.

Three further consequences worth stating up front:

- Hyprland cannot know where point is, so it cannot place point-anchored UI.
- Hyprland cannot know a popup should vanish when point moves, so it cannot manage its
  lifetime.
- Tiling a popup would move focus out of the buffer being typed into.

### Granularity: hybrid, not strict

Default is one buffer per frame, but Emacs may still split a frame **at most 2 ways** for
genuinely paired buffers (magit/diff, test/impl, org src/preview). Strict frames-only was
rejected — see [decisions.md](decisions.md) §1 — chiefly because org-mode, ediff and magit all
assume they may split at will, and fighting them costs more than it returns.

A side effect that matters for the visual goals: because one buffer is one frame, **opening a
buffer is a real animated window open**. Emacs cannot animate its internal splits and does not
have to.

## 3. The WM bridge: one component, not five

The unified ace, the clipboard watcher, the window mark-ring and the per-workspace project
environment all need the same thing — a long-lived reader on Hyprland's event socket
(`$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock`) plus persistent elisp
state. Building that once, inside the Emacs daemon, is most of what keeps this project small.

```
        Hyprland .socket2.sock   (activewindow, workspace, openwindow, closewindow)
                    |                                    ^
                    v                                    | hyprctl dispatch (fire and forget)
        +-------------------------------------+          |
        |  wm-bridge.el  (in the Emacs daemon)|----------+
        |  state mirror | ace | mark-ring     |
        |  kill-ring sync | per-ws project env|
        +-------------------------------------+
                    |
                    v  written on change, never queried synchronously
          $XDG_RUNTIME_DIR/wm-bridge/state.json   <-- read by Hyprland-side dispatchers
```

The direction of every arrow is load-bearing. Emacs is a **client** of Hyprland's socket, so a
wedged Emacs simply stops reading and Hyprland neither knows nor cares. Hyprland-side key
dispatchers **read a cache file**, never query Emacs. Section 5 explains why this is
non-negotiable.

## 4. Layout: a scrolling strip

**The scrolling layout is built into Hyprland core** as of the pinned 0.56.0 — no plugin at
all. Verified against the binary: `scrolling` appears as a layout name and all twelve config
keys live under the `scrolling:` namespace (`column_width`, `explicit_column_widths`,
`focus_fit_method`, `follow_focus`, `follow_min_visible`, `fullscreen_on_one_column`,
`direction`, `wrap_focus`, `wrap_swapcol`, `move_snap_cursor`, `move_snap_to_grid`,
`focus_decoration`) with no `plugin:` prefix. `layoutmsg` supports `fit` (with `active`, `all`,
`visible`, `tobeg`, `toend`), `colresize`, `promote` and `expel`.

This is a material simplification over the original plan, which assumed a plugin from
`hyprwm/hyprland-plugins`: there is no plugin to build, no ABI to track and no flake input that
can break the layout on update. The `hyprland-plugins` input ships only
`borders-plus-plus`, `csgo-vulkan-fix`, `hyprbars` and `hyprfocus` at the pinned revision, and
is not needed for the layout.

A workspace is an infinite horizontal strip of columns; the monitor is a viewport onto it.
This is the only layout that survives the hybrid model, which routinely produces 8-15 windows
per workspace:

```
dwindle, 10 windows            scrolling, 10 windows
+----+--+-+-+------+           +--------+--------+--------+  -> -> ->
|    |  | | |      |           | config | magit  | eshell |
|    +--+-+-+  +---+           |  .org  |        |        |
+----+-+-+--+  |   |           +--------+--------+--------+
|    | | |  |  +-+-+|          viewport scrolls; every window keeps
+----+-+-+--+  | | ||          a usable width regardless of count
unreadable
```

It also supplies something Emacs needs: an unambiguous **linear order** over every window in a
workspace, which is what makes `windmove-left/right` and `C-x o` semantics well-defined across
the whole desktop rather than only within a frame.

## 5. Invariant: the window manager never blocks on Emacs

The obvious implementation of this project contains a fatal dependency inversion. If `SUPER+h`
routes through `emacsclient --eval`, then a blocking LSP call, a GC pause, a runaway elisp loop
or an oversized clipboard makes **the window manager stop responding because the editor is
busy**. A desktop that can be bricked by its text editor is not acceptable, so this is settled
in the architecture rather than patched later.

Four rules, in priority order:

1. **Every Emacs call from a keybind has a hard timeout (~100-150 ms) and a defined
   pure-Hyprland fallback.** `SUPER+h` against a wedged Emacs degrades to plain
   `hyprctl dispatch movefocus l`. The desktop keeps working; only the Emacs-aware refinement
   is lost.
2. **The fast path does not call Emacs at all.** The bridge *pushes* its state — frame
   geometry, which windows are Emacs, inner window layout — to `state.json` on
   `window-configuration-change-hook`. Dispatchers read the file, which takes microseconds and
   cannot hang. Emacs is invoked only to *act*, and a failed action is a fallback rather than a
   freeze.
3. **Emacs never owns anything the desktop needs.** Wayland keeps owning the clipboard; the
   bridge only observes it. Pasting in Chromium must work with Emacs dead.
4. **Escape hatches that do not involve Emacs**: restart the daemon, spawn a terminal, and a
   panic bind that swaps in a Hyprland-only keymap via `hyprctl keyword`. See
   [keys.md](keys.md) §5.

Tier-3 ghostty (§6) existing as a real WM window is itself a robustness property, not only a
performance one: there is always a working terminal that does not depend on Emacs.

### Recovery

The bridge persists nothing. On init it rebuilds its mirror from one `hyprctl clients -j` plus
`hyprctl workspaces -j`. State that *is* worth keeping — kill-ring, mark-ring — goes in
`savehist`; frames and buffers are already covered by the existing `desktop-save-mode`.
`systemctl --user restart emacs.service` (already wrapped by `my/restart-emacs-from-profile` in
`emacs/config.org`) is therefore a clean recovery with no manual reattach step.

**Known rough edge, to be designed for rather than discovered:** `desktop-save-mode` restoring
N frames under one-buffer-per-frame means Hyprland re-tiles them in *restore* order, which need
not match the strip order that was in use. Emacs must record each frame's strip index and
reinsert accordingly.

**Watchdog policy: notify, never auto-restart.** A systemd timer pings the server with a hard
timeout and, after 3 consecutive failures, fires a desktop notification naming the restart
bind. It never acts on its own, because an auto-restart would sometimes kill a legitimately
long computation or discard state `desktop-save-mode` had not yet checkpointed.

## 6. Terminal: three tiers, forced by single-threadedness

Emacs is single-threaded, and terminal output is handled by a process filter competing with
redisplay on the main thread. So a chatty command does not merely make the terminal slow, it
**stutters your editing everywhere**. This is the existing "a CAPF must never block" rule
generalised, and it forces three tiers rather than two.

| Tier | Tool | For |
|---|---|---|
| 1 | eshell | interactive shell work; where Emacs integration pays off |
| 2 | eat (`eat-eshell-mode`) | TUIs you interact with: htop, interactive rebase, ssh to the pi |
| 3 | ghostty, a real Hyprland window | firehose output, long unattended jobs |

Measured context: vterm is ~1.5x faster than byte-compiled eat, and eat is ~3x faster than
`term`. That gap only matters for megabyte bursts, which is exactly what tier 3 exists to
absorb, so eat is chosen and no native module enters the Emacs closure. A 20-minute aarch64
build has no business inside the editor's event loop.

**Long builds, searchable, without blocking:** do not use a process filter at all. Run detached
to a log file — already this repo's convention — and put `auto-revert-tail-mode` plus
`compilation-mode` on the log. Emacs reads increments on a timer *it* controls, giving zero
process-filter pressure, full isearch/occur, and the ability to pause reverting while
searching. The same build is then live in ghostty and searchable in Emacs simultaneously.

## 7. Browser

Chromium, with a pinned extension and a stdio native-messaging host bridging to the Emacs
server over a unix socket. Tab management wants **push** events, not polling — that is the
difference between a novelty and something that genuinely feels like buffer switching. The CDP
debug port was rejected; see [decisions.md](decisions.md) §3.

Target: a `consult-buffer` source listing live tabs alongside buffers, plus activate, close and
move tab, and capture page to org-roam.

## 8. Build order

Phase 1 is a scaffold and a minimal desktop, and its bar for done is **KDE uninstalled and this
is daily-driveable**. Phase 2 adds the Emacs-native layer, ordered so each step is
independently useful.

1. Palette contract and keybind attrset: `palette.json` roles, the `theme-apply` script, and
   the derivation emitting `binds.conf`. Two single-sources-of-truth, same shape.
2. `home/hyprland.nix` filled in: monitors, hyprscrolling, decoration, workspaces, hot path.
3. KDE replacement: notifications, portal, lock/idle, polkit, bar.
4. Emacs tier-2 policy: `display-buffer-alist`, `which-key-mode`, palette consumption,
   frame-title tagging.
5. Escape hatches and watchdog — before anything depends on the bridge.
6. Bridge skeleton: socket reader, state mirror, cache file.
7. Directional movement across the boundary.
8. Terminal tiers and log tailing.
9. Kill-ring as system clipboard.
10. Overlay engine, then unified ace on top of it.
11. Window mark-ring.
12. Chromium tabs as buffers.
13. Per-project environment isolation.
14. Workspace spanning across monitors.
15. Screenshare hygiene.

Phase 2 does not begin until Phase 1 is boring.

### Status

Steps 1, 2, 4 and the Emacs half of 7 are built. Everything is **inert**: `local.wm.enable`
defaults to
false, so no package reaches PATH, and the generated `hyprland.conf` is only read if Hyprland
is started. Plasma is untouched, and `xdg.portal.enable = lib.mkForce false` is preserved so
xdg-desktop-portal-kde keeps working.

Deliberately deferred, because the dependency is not installed and binding to a missing binary
is worse than an absent binding:

| Deferred | Why | Lands with |
|---|---|---|
| KDE replacement (step 3) | still the live session | when you switch |
| Bar, launcher (`SUPER SPC`) | no bar chosen or installed | step 3 |
| Grab submap (`SUPER g`) | grim/slurp not installed | step 3 |
| Lock binding | no locker installed | step 3 |
| ghostty | not installed; kitty used for the terminal and escape-hatch bindings | step 8 |

Verified by test rather than assumed:

- **Never-block invariant.** With a stubbed `emacsclient` that sleeps 30 s, a keybind falls back
  in ~165 ms. Also covered: Emacs handling it (zero `hyprctl` calls), declining, and
  `emacsclient` absent entirely.
- **Emacs round-trip latency: 7 ms mean** over 20 calls against a live daemon, against the
  150 ms budget. This was an explicit prerequisite before depending on `emacsclient --eval`.
- **The shell/elisp protocol.** `emacsclient --eval` prints `"t"` with quotes, which is what the
  dispatcher compares; confirmed against a real daemon rather than assumed.
- **End to end**, `wm-dispatch` → real `emacsclient` → real daemon: an internal move issues no
  `hyprctl`, an edge move falls back, and a frame with no splits always falls back.
- **Elisp behaviour**, 20 assertions in `emacs --batch`: directional focus returning nil at frame
  edges, entry-edge landing on the furthest window across three columns, palette load and face
  application, roles surviving a failed reload, and the policy defaults.
- Four assertion classes in nix, the comma-versus-space dispatcher form, and scheme polarity
  genuinely driving shadow enablement.

Not verifiable without a running Hyprland, and recorded as such: whether `noshadow` is a valid
rule property, whether the `layoutmsg` arguments are spelled as assumed, and whether pgtk
reports the Emacs `class` as `emacs` for the windowrule match.

## 9. Open questions

- **Workspace model.** Deferred. Defaults to per-monitor numeric (each monitor independently
  owns 1-9), which is robust to docking. Project grouping lives in Emacs `tab-bar`/`project.el`
  rather than being duplicated in the WM.
- **Column flexibility.** `hyprscrolling` gives columns with vertical stacking, plus both
  free-form `colresize` and width presets, but **not** arbitrary recursive nesting inside a
  column. Recursive nesting exists one level down, inside an Emacs frame's window tree, which
  genuinely is a recursive binary split. The resulting model has three axes: strip → column
  stack → Emacs window tree. Confirm this is enough before building.
- **Transient surfaces.** Layer-shell overlays are chosen but not yet validated. The fallback,
  a Hyprland special workspace, is cheaper but takes focus and appears in screenshare. Revisit
  after step 10, since the overlay engine is the deciding cost.
- **Emacs frame focus indication** once borders are removed from Emacs windows — see
  [theme.md](theme.md) §5.
- **Continuous theming.** The palette contract ([theme.md](theme.md) §1) makes schemes
  runtime-swappable, which is the prerequisite. Driving it continuously from time of day, screen
  brightness or the wallpaper is a later producer, not a redesign — but which signal drives it,
  and how often it may change without being distracting, is undecided.

## 10. Verification

Each phase has a gate rather than a vibe.

- **Phase 1 gate:** log in with Plasma removed and do a normal day — bar, notifications, lock,
  screenshare, portal file picker, audio, both monitors, dock and undock.
- **Robustness, tested deliberately:** wedge Emacs with `(while t)` via emacsclient, then
  confirm `SUPER+h` still moves focus, `SUPER+y` degrades gracefully, paste still works in
  Chromium, the notification fires, the ghostty bind works, and restarting the service recovers
  with the bridge reattached and both rings intact.
- **Directional:** measure the `emacsclient --eval` round trip before relying on it; enter an
  Emacs frame from all four directions and assert the correct edge window is selected.
- **Kill-ring:** copy in Chromium and confirm exactly one ring entry (origin token works); copy
  a large image and confirm no main-thread stall and a file path in the ring.
- **Mark ring:** ace three times across apps yields three entries; `SUPER+h` ten times yields
  zero; `C-x C-SPC` pops through both kinds.
- **Terminal:** run a firehose command in eat and in ghostty while typing in another Emacs
  frame. Confirm ghostty does not stutter Emacs and eat does — this validates the tiering
  rationale rather than assuming it.
- **Screenshare:** share an output, trigger ace, the kill-ring picker and a notification, and
  confirm none appear in the capture.
- **Multi-monitor:** undock and redock mid-session; confirm workspaces and strip survive, then
  join, interleave, split apart and verify original grouping and order are restored.

Rebuilds go through the `nix-build` and `nix-deploy` skills. This repo is a separate clone per
host: push and pull before treating any host as validated.

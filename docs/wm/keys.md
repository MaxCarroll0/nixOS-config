# Keymap specification

Why this exists: this desktop introduces two new keymaps at once (Hyprland's and an extended
Emacs one) and they must not drift apart. This document is the spec that
`modules/home/wm/keys.nix` encodes; the nix attrset generates the Hyprland `binds.conf`, the
Emacs `keys.el`, and both which-key panels from one source, so the help can never disagree with
the actual bindings.

Keyboard context: gb layout, `caps:escape` already set in `modules/nixos/desktop-env.nix`.
`SUPER` is the WM modifier throughout and is never used by Emacs, so no key is contested.

## 1. Structure

Flat `SUPER` chords for the hot path, Emacs-style prefix submaps for the long tail. The split
is by frequency, not by category: anything pressed hundreds of times a day gets a single chord
and no modal state, everything else gets a discoverable prefix.

Hyprland `submap`s are modal prefix keymaps — the direct analogue of `C-x` in Emacs. Entering
one raises a which-key panel (see §4) and any unbound key exits it.

## 2. Flat hot path

| Key | Action | Owner |
|---|---|---|
| `SUPER h/j/k/l` | focus left/down/up/right, crossing the Emacs boundary | bridge |
| `SUPER H/J/K/L` | move the focused window in that direction | Hyprland |
| `SUPER 1-9` | workspace N **on this monitor** | Hyprland |
| `SUPER SHIFT 1-9` | move window to workspace N | Hyprland |
| `SUPER Tab` | last workspace | Hyprland |
| `SUPER o` | unified ace: jump to any window or Emacs split, all monitors | bridge |
| `SUPER SHIFT o` | ace: swap focused window with the chosen one | bridge |
| `SUPER b` | switch buffer, window or Chromium tab (one `consult-buffer`) | Emacs |
| `SUPER y` | kill-ring picker; types the selection into the focused window | bridge |
| `SUPER ,` | pop the unified mark ring (back) | bridge |
| `SUPER .` | unpop the mark ring (forward) | bridge |
| `SUPER Return` | eshell at the focused window's cwd (`/proc/PID/cwd`) | bridge |
| `SUPER SHIFT Return` | ghostty at the focused window's cwd | bridge |
| `SUPER SPC` | application launcher | Hyprland |
| `SUPER q` | close focused window | Hyprland |
| `SUPER f` | toggle column full width | Hyprland |

`SUPER h/j/k/l` deliberately does **not** push the mark ring. See §6.

## 3. Submaps

Entered with a `SUPER` chord, exited with `Escape` or any unbound key.

### `SUPER w` — window and column

| Key | Action |
|---|---|
| `h` / `l` | move this window left/right in the strip |
| `j` / `k` | move this window within its column stack |
| `s` | stack a new window into this column |
| `w` | cycle column width through presets (0.333, 0.5, 0.667, 1.0) |
| `+` / `-` | free-form column resize |
| `f` | fit visible columns to the screen |
| `d` | close window |
| `t` | toggle floating |

### `SUPER s` — session and system

| Key | Action |
|---|---|
| `l` | lock |
| `s` | suspend |
| `r` | restart the Emacs daemon |
| `R` | reload Hyprland config |
| `q` | log out |

### `SUPER p` — project

| Key | Action |
|---|---|
| `p` | switch project (workspace adopts its direnv environment) |
| `e` | eshell in project root |
| `d` | dired in project root |
| `g` | magit status for project |

### `SUPER g` — grab and share

| Key | Action |
|---|---|
| `r` | screenshot region |
| `w` | screenshot window |
| `o` | screenshot output |
| `s` | toggle share-safe mode (see [theme.md](theme.md) §7) |

### `SUPER m` — monitor and workspace surgery

| Key | Action |
|---|---|
| `j` | join this workspace with the adjacent monitor's into one strip |
| `s` | split a joined strip apart again, restoring home workspaces in order |
| `h` / `l` | move focus to the monitor left/right |
| `H` / `L` | move this window to the monitor left/right |

## 4. Discoverability

Learning two keymaps at once is the main usability risk, so feedback is a requirement rather
than polish.

- **Emacs:** `which-key-mode`, which is **built into Emacs 30+** — the config runs 30.2, so no
  new package is needed. Rendered as a child frame (tier 2) to match the WM panel visually.
  `meow-cheatsheet` already exists on `SPC ?`.
- **Hyprland:** entering a submap raises a layer-shell which-key panel, drawn by the same
  overlay engine as the ace and the kill-ring picker. Built once, used three times.
- **Bar indicator:** the active submap is shown persistently, so it is impossible to be in a
  mode without knowing.
- **Generated from the same attrset as the bindings**, so a panel can never describe a keymap
  that no longer exists.

```
SUPER+w  ->  +--------------------------+
             |  window                  |
             |  h / l   move in strip   |
             |  j / k   move in stack   |
             |  s stack     d close     |
             |  w cycle width           |
             |  ESC / any other: exit   |
             +--------------------------+
```

## 5. Escape hatches

These must work with Emacs wedged, and therefore must be pure Hyprland dispatchers with no
bridge involvement. Deliberately awkward chords, because they are emergencies and must never
fire by accident.

| Key | Action |
|---|---|
| `SUPER CTRL ALT r` | `systemctl --user restart emacs.service` |
| `SUPER CTRL ALT e` | spawn ghostty (guaranteed terminal, no Emacs dependency) |
| `SUPER CTRL ALT p` | panic: swap in a Hyprland-only keymap via `hyprctl keyword` |

The panic keymap rebinds `SUPER h/j/k/l` and `SUPER o` to their plain `hyprctl` equivalents,
so the desktop remains fully navigable with the bridge disabled.

Note this is belt-and-braces: per README §5 rule 1, every bridge binding *already* degrades to
its Hyprland fallback on timeout. The panic bind exists for the case where the bridge is
responding but wrong.

## 6. What pushes the mark ring

The mechanism is easy; the design question is what counts as a push. If every focus change
pushed, the ring would fill with alt-tab noise and popping would be unpredictable. Emacs
already solved this: **jumps push, motion does not** — the same distinction as `C-SPC` versus
`C-f`.

| Pushes | Does not push |
|---|---|
| `SUPER o` ace jump | `SUPER h/j/k/l` directional movement |
| `SUPER 1-9` workspace switch | `SUPER w` submap window moves |
| `SUPER b` buffer/tab switch | mouse click focus |
| `SUPER p p` project switch | |

Entries are `(buffer . point)` or `(hyprland-window . address)`. `C-x C-SPC` in Emacs and
`SUPER ,` at the WM level pop the same ring, and popping does either `goto-char` or
`hyprctl dispatch focuswindow`.

## 7. Ownership

Every binding is dispatched by exactly one of three parties, and the attrset records which.

- **Hyprland** — pure dispatcher, no Emacs involvement, works when Emacs is dead.
- **Emacs** — sent to the daemon; meaningless if Emacs is dead, which is acceptable for these.
- **bridge** — consults `state.json`, acts via Emacs *or* `hyprctl`, and **must declare a
  pure-Hyprland fallback**. A bridge binding without a declared fallback is a spec violation and
  should fail nix evaluation.

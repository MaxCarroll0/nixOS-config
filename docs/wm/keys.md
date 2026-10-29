# Keymap specification

Why this exists: this desktop introduces two new keymaps at once (Hyprland's and an extended
Emacs one) and they must not drift apart. This document is the spec that
`modules/home/wm/keys.nix` encodes; the nix attrset generates the Hyprland `binds.conf`, the
Emacs `keys.el`, and both which-key panels from one source, so the help can never disagree with
the actual bindings.

Keyboard context: gb layout. Under Hyprland, Caps Lock is `caps:none` and bound by keycode as the NORMAL leader.
`SUPER` is the WM modifier throughout and is never used by Emacs, so no key is contested.

## 1. Structure

The WM keymap behaves like meow with which-key. There are two ways to reach every command, and
both are generated from the same attrset in `home/hyprland.nix`:

- **Chords, from anywhere:** flat `SUPER` chords for the hot path, plus `SUPER` + a letter for
  each prefix map. These work in apps and in NORMAL alike.
- **NORMAL state, like meow normal:** Caps Lock (or `s-ESC`) enters a sticky `normal` submap.
  The bar always shows the mode (`I` or `N`), and NORMAL lightens the shell frame and thickens
  window borders. Caps Lock on a focused Emacs is first offered to Emacs, which leaves insert
  state if it is in one and otherwise hands back NORMAL; a fullscreen window just gets `Escape`,
  and going fullscreen leaves NORMAL. Inside it, every plain
  `SUPER`/`SUPER SHIFT` chord also works with `SUPER` dropped (`h`, `H`, `1`, `q` ...), the
  prefix maps open on their bare letter (`w s g m p`), and `SPC` opens the **keypad**: a leader
  holding the prefix maps plus a few keypad-only bindings (`SPC SPC` launcher, `SPC /` reference).
  `i` or `ESC` goes back to the apps; Caps Lock inside a prefix map returns to NORMAL. Unbound keys are swallowed, as in meow; mouse
  input passes through, and `BKSP` steps out of a prefix map.

Hyprland `submap`s are the prefix maps, the direct analogue of `C-x` in Emacs. A prefix map runs
one command and exits, back to wherever it was entered from (the apps or NORMAL), unless it is
`sticky` (the window map, so moves repeat). Global binds are inactive inside a submap, so the
generator copies the global chords into `normal` and emits every prefix map twice: `NAME` for
the chord route and `normal:NAME` for the NORMAL route.

A binding marked `insert` hands the keyboard to an application (launcher, eshell, consult, ace,
project prompts). From NORMAL it returns to the apps after running, the way meow commands drop
into insert state; which-key marks these with ↩.

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
- **Hyprland:** entering the keypad or a prefix map raises a which-key panel drawn inside the
  **Caelestia** shell (`quickshell/caelestia/modules/whichkey/`), on the overlay layer with no
  keyboard focus, in Caelestia's colours and fonts. It shows a breadcrumb (`NORMAL` `SPC`
  `w`), `+prefix` entries, and ↩ on `insert` bindings.
- **Bar indicator:** an `N` pill under the bar's logo while in NORMAL or anything entered from it,
  so it is impossible to be in a mode without knowing.
- **Reference:** the dashboard's Keybinds tab (`s-/`, or `SPC /` in NORMAL) lists everything in
  Emacs key notation.

All three are **built**. The panel appears after a ~400 ms idle delay, so a fast chord never
flashes it, matching `which-key-idle-delay`; once visible it follows deeper prefixes without
waiting again. Caelestia learns the active submap from Hyprland's `submap` event (`WmState`
singleton) rather than the bindings pushing to it, so the keymap generator stays ignorant of the
UI and the two cannot desynchronise. Rows come from the `modes` in the generated
`~/.config/wm/help.json`, watched for changes.
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
| `SUPER CTRL ALT p` | panic: make every bridge key dispatch directly, skipping Emacs |

Panic is a **flag file**, not a rebind. `wm-panic` touches
`$XDG_RUNTIME_DIR/wm-bridge/panic`; `wm-dispatch` checks for it first and, when present, goes
straight to the declared Hyprland fallback without contacting Emacs at all. `wm-panic off`
clears it. This is simpler than rebinding, needs no keyword system (which 0.56 does not have —
README §3a), and is directly testable. Verified live: with the flag set, a bridge key dispatched
in 28 ms and Emacs's own window did not move; cleared, Emacs handled it again.

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

The `dispatch` field holds a **Lua dispatcher expression**, e.g.
`hl.dsp.focus({ direction = "l" })`, used verbatim both as the bind target and as the argument
to `hyprctl dispatch` in the fallback. It is not a legacy dispatcher string: 0.56 has no such
thing (README §3a). Key specs join modifiers with `+`, as `SUPER+SHIFT+Return`.

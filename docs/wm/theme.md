# Visual specification

Why this exists: the look is derived from a specific reference rice rather than invented, and
several of its values had to change because this setup uses a scrolling layout and a laptop
battery. More importantly, colour must be **abstract**: no app config may contain a hex code,
so that schemes can be swapped at runtime and eventually driven continuously by time of day,
screen brightness or the wallpaper. This records the abstraction, the current scheme, and every
deviation from the reference with its reason.

Reference geometry: [Nytril-ark/rumda](https://github.com/Nytril-ark/rumda). Current scheme:
gruvbox light hard.

## 1. Colour architecture

Three layers, and the middle one is the contract. **No consumer ever names a scheme or a hex
code — only a role.**

```
  producers (any number, one active)
  ---------------------------------
  gruvbox-light   gruvbox-dark   matugen(wallpaper)   interpolate(time, brightness)
         \             |               |                      /
          v            v               v                     v
             +--------------------------------------+
             |  palette.json                        |   <-- THE CONTRACT
             |  semantic roles -> hex, + polarity   |
             +--------------------------------------+
                              |
                       theme-apply
              /         |          |         \        \
        hyprctl      eww        emacs      ghostty    notifications
        keyword     reload   load-theme     reload
```

- **Producers** compute a palette. Adding gruvbox dark, a wallpaper-derived scheme via
  `matugen`, or a time-interpolated one is adding a producer — nothing downstream changes.
- **`palette.json`** is the only interface. Roles plus a `polarity` field (§4 depends on it).
- **`theme-apply`** pushes the active palette into every consumer *without a rebuild*, using
  each app's live-reconfiguration path.

Consequence for the nix side: nix generates the *scheme data* and the *generators*, but the
active palette is a runtime file. This is the seam that makes continuous theming an increment
later rather than a redesign. A build-time-only design (which is what stylix gives you) would
require a rebuild per switch and could never be continuous.

Ecosystem pieces worth borrowing rather than reimplementing: `base16-schemes` for scheme data,
`matugen` for wallpaper-derived palettes. Both can emit `palette.json`, so both are just
producers.

## 2. Semantic roles

Kept deliberately small. If a consumer needs a colour not in this list, the right fix is
usually to reuse a role, not to add one.

| Role | Meaning |
|---|---|
| `bg` | window and desktop background |
| `bg-alt` | secondary background: bar, panels |
| `surface` | raised surface: overlays, popups, which-key panel |
| `overlay` | modal scrim |
| `fg` | primary text |
| `fg-dim` | secondary text, inactive modeline |
| `fg-faint` | comments, disabled, line numbers |
| `border-active` | focused window border |
| `border-inactive` | unfocused window border |
| `sel-bg` / `sel-fg` | selection and region |
| `accent` | primary accent: active bar module, ace labels |
| `accent-alt` | secondary accent |
| `ok` / `info` / `warn` / `error` | status semantics |
| `ansi0`-`ansi15` | terminal palette, required by ghostty and eat |
| `polarity` | `light` or `dark`; generators branch on it (§4) |

`polarity` is a first-class field rather than an implicit property of the hexes, because real
geometry decisions depend on it — see §4. A generator that ignores `polarity` will produce a
correct-looking palette with wrong decoration.

## 3. Current scheme: gruvbox light hard

The `bg`/`fg` ramps invert relative to gruvbox dark, and the accent role played by `bright` in
dark is played by **faded** (darker, more saturated) in light, because an accent must be darker
than the background to read.

| | Hex | | Hex |
|---|---|---|---|
| `bg` | `#f9f5d7` | `fg` | `#3c3836` |
| `bg-alt` | `#fbf1c7` | `fg-dim` | `#504945` |
| `surface` | `#ebdbb2` | `fg-faint` | `#7c6f64` |
| `sel-bg` | `#d5c4a1` | `sel-fg` | `#282828` |
| `border-active` | `#af3a03` | `border-inactive` | `#d5c4a1` |
| `accent` | `#af3a03` | `accent-alt` | `#076678` |
| `ok` | `#79740e` | `warn` | `#b57614` |
| `error` | `#9d0006` | `info` | `#076678` |
| `polarity` | `light` | | |

Full gruvbox light ramp, for the generator:

```
bg:   bg0_h #f9f5d7  bg0 #fbf1c7  bg1 #ebdbb2  bg2 #d5c4a1  bg3 #bdae93  bg4 #a89984
fg:   fg0 #282828  fg1 #3c3836  fg2 #504945  fg3 #665c54  fg4 #7c6f64  gray #928374
             normal    faded              normal    faded
red        #cc241d  #9d0006     purple  #b16286  #8f3f71
green      #98971a  #79740e     aqua    #689d6a  #427b58
yellow     #d79921  #b57614     orange  #d65d0e  #af3a03
blue       #458588  #076678
```

The active/inactive border contrast is deliberately larger than gruvbox dark would need,
because §5 removes borders from Emacs frames entirely and the remaining borders carry more work.

## 4. Geometry, and the deviations from rumda

| | rumda (light) | here | why |
|---|---|---|---|
| `gaps_out` | 40-45 | 40 | keep — the airy frame around the whole desktop is the signature |
| `gaps_in` | 9 | **0** | see §5 |
| `border_size` | 3 | 3 non-Emacs, 0 Emacs | separation moves from gaps onto borders |
| `rounding` | 7 | 7 non-Emacs, 0 Emacs | ditto |
| blur | size 1, passes 2, vibrancy 0.1696 | same, re-tune on `polarity` | blur reads differently over light backgrounds |
| shadows | **enabled** (range 7, power 9, offset 5 4) | enabled when `polarity = light` | see below |
| `inactive_opacity` | 0.99 | 0.99 | keep; subtle |
| `layout` | dwindle | `scrolling` | dwindle is unusable at 10+ windows; README §4. Core in 0.56, no plugin |
| `borders-plus-plus` | double borders | deferred | in the `hyprland-plugins` input; not Phase 1 |
| `vfr` | `false` | `true` | `vfr = false` renders continuously and burns laptop battery, fighting `modules/nixos/power.nix` |
| `allow_tearing` | `true` | `false` | tearing is for games; this is a text-first desktop |
| `kb_layout` | us, ara | gb | per `modules/nixos/desktop-env.nix` |
| `follow_mouse` | 1 | 0 | focus must not follow the mouse; [decisions.md](decisions.md) §4 |

**Shadows are polarity-dependent, and this is the reason `polarity` is a palette field.**
rumda's dark config disables shadows; its light config enables them. That is not a taste
difference: on a light background, borders are low-contrast against the desktop and shadow does
the work of separating a window from what is behind it. So shadow enablement and blur vibrancy
are computed from `polarity`, not hardcoded — otherwise swapping to a dark scheme at runtime
would produce a correct palette with wrong decoration.

## 5. Gaps and seams

Requirement: generous gaps around the whole desktop, but **adjacent Emacs frames must abut with
no gap**, so N single-buffer frames read as one continuous Emacs surface rather than N separate
windows.

Hyprland has **no per-window gaps rule** — gaps are layout- and workspace-level
(`workspace = w[…], gapsin:0`), so this cannot be expressed as gaps at all. Invert it: set
`gaps_in = 0` globally and let **borders and rounding** carry the separation, applied per window
by rule.

```
gaps_out = 40, gaps_in = 0

 +----------------------------------------------------+
 |                                                    |  <- gaps_out: airy desktop frame
 |   +--------++--------++--------+  ,-----------.    |
 |   | config || magit  || eshell |  | chromium  |    |
 |   |  .org  ||        ||        |  |  b=3 r=7  |    |
 |   +--------++--------++--------+  `-----------'    |
 |    \___ Emacs: b=0 r=0, frames fuse ___/           |
 |                                                    |
 +----------------------------------------------------+
```

Emacs frames take `bordersize 0, rounding 0` and fuse seamlessly; everything else keeps
`border_size 3` and `rounding 7` and reads as a distinct window. Matched on the frame-title
tagging introduced in Phase 1 step 4.

**Shadows must also be suppressed on Emacs frames** (`noshadow`), for the same reason as
borders: with light-polarity shadows enabled, adjacent fused frames would each cast a shadow onto
the next and reintroduce a visible seam — the exact thing `gaps_in = 0` is there to remove.

**Open question — focus indication.** With no border, Hyprland's `border-active` role can no
longer show which Emacs frame has focus. The consistent answer is that **Emacs owns its own
focus indication**: active versus inactive modeline face, and per-frame `internal-border`
colour, both of which Emacs can already set per frame, and both of which read their colours from
the same roles. This is the policy/mechanism split applied to decoration and is the
recommendation. If it reads too subtly in practice, the fallback is `bordersize 1` on Emacs
frames using `border-active`/`border-inactive` — a 2 px seam between frames, nearly invisible
but unambiguous. Decide by looking at it during Phase 1.

## 6. Animations

Kept broadly as rumda has them. Beziers:

```
easeOutQuint    0.23, 1,    0.32, 1
easeInOutCubic  0.65, 0.05, 0.36, 1
almostLinear    0.5,  0.5,  0.75, 1.0
quick           0.15, 0,    0.1,  1
fakeElastic     0.68, -0.1, 0.265, 1
xfcBezier       0.1,  0.9,  0.1,  1.03
```

| Animation | Value |
|---|---|
| `windows` | `1, 4.79, easeOutQuint` |
| `windowsIn` | `1, 4, default, slide bottom` |
| `windowsOut` | `1, 8, default, slide top` |
| `windowsMove` | `1, 3, fakeElastic, slide` |
| `border` | `1, 1.39, easeOutQuint` |
| `fade` | `1, 3.03, quick` |
| `layers` | `1, 3.81, easeOutQuint` |
| `layersIn` | `1, 4, easeOutQuint, fade` |
| `layersOut` | `1, 1.5, linear, fade` |
| `workspaces` | `1, 4, xfcBezier` |

Because one buffer is one frame, `windowsIn` means **Emacs buffer switching is animated** — the
"animations including for Emacs" requirement is satisfied structurally, with no changes to Emacs
at all.

`layers*` covers the bar, the ace overlay, the kill-ring picker and the which-key panel, so all
transient surfaces fade consistently.

## 7. Screenshare hygiene

Transient surfaces must never leak into a capture. `noscreenshare` rules apply to the ace
overlay, the kill-ring picker, notifications and password prompts.

Rule syntax is settled for the pinned 0.56.0: `windowrule` occurs in the binary and
`windowrulev2` does **not**, so v2 has been folded in and the unsuffixed form is correct.

Still unverified, and honestly not verifiable without running Hyprland: whether the specific
rule *properties* `noshadow` and `noscreenshare` exist under those names. Grepping the binary
for them returns nothing, but so does grepping for `layerrule`, which certainly exists — so the
grep is not evidence either way for rule properties. Confirm with `hyprctl keyword` on first
real session before depending on either. The screenshare rules are a Phase 2 step 15 task; the
`noshadow` rule matters sooner, because §5 depends on it.

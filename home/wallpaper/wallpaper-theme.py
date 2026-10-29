# wallpaper-theme: random wallpaper per light/dark mode, with a gruvbox-shaped scheme drawn from it.

import argparse
import hashlib
import json
import math
import os
import random
import subprocess
import sys
from datetime import datetime, time, timedelta
from pathlib import Path

from astral import Observer
from astral.sun import sun
from PIL import Image

GENERATOR_VERSION = 4
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}
DARK_LIGHTNESS = 0.52
DUSK_CAST_CHROMA = 0.04
DUSK_CAST_HUES = (20, 90)
TONES = {
    "light": {"skeleton": "light", "polarity": "light", "hues": (70, 130), "lift": 0.0, "warmth": 1.0, "mute": 1.0},
    "dusk": {"skeleton": "dark", "polarity": "dark", "hues": (50, 80), "lift": 0.05, "warmth": 1.8, "mute": 0.85},
    "dark": {"skeleton": "dark", "polarity": "dark", "hues": (70, 130), "lift": 0.0, "warmth": 1.0, "mute": 1.0},
}
FALLBACK_POOLS = {"light": ["light"], "dusk": ["dusk", "dark"], "dark": ["dark"]}
NEUTRAL_ROLES = {
    "bg", "bg-alt", "surface", "overlay", "fg", "fg-dim", "fg-faint",
    "border-inactive", "sel-bg", "sel-fg", "ansi0", "ansi7", "ansi8", "ansi15",
}
FAMILY_ROLES = {
    "red": "ansi9",
    "orange": "accent",
    "yellow": "ansi11",
    "green": "ansi10",
    "aqua": "ansi14",
    "blue": "ansi12",
    "purple": "ansi13",
}

config = json.loads(Path(os.environ["WALLPAPER_THEME_CONFIG"]).read_text())
state_dir = Path(config["stateDir"])
cache_dir = Path(config["cacheDir"])
state_file = state_dir / "state.json"


def to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def from_linear(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def rgb_to_oklab(r, g, b):
    r, g, b = to_linear(r), to_linear(g), to_linear(b)
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    )


def oklab_to_linear(L, a, b):
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    return (
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    )


def hex_to_lch(h):
    r, g, b = (int(h.lstrip("#")[i:i + 2], 16) / 255 for i in (0, 2, 4))
    L, a, bb = rgb_to_oklab(r, g, b)
    return L, math.hypot(a, bb), math.degrees(math.atan2(bb, a)) % 360


def in_gamut(rgb):
    return all(-1e-4 <= c <= 1 + 1e-4 for c in rgb)


def lch_to_hex(L, C, h):
    L = min(max(L, 0.0), 1.0)
    rad = math.radians(h)
    lo, hi = 0.0, C
    rgb = oklab_to_linear(L, C * math.cos(rad), C * math.sin(rad))
    if not in_gamut(rgb):
        for _ in range(24):
            mid = (lo + hi) / 2
            if in_gamut(oklab_to_linear(L, mid * math.cos(rad), mid * math.sin(rad))):
                lo = mid
            else:
                hi = mid
        rgb = oklab_to_linear(L, lo * math.cos(rad), lo * math.sin(rad))
    return "#" + "".join(
        f"{round(min(max(from_linear(min(max(c, 0.0), 1.0)), 0.0), 1.0) * 255):02x}" for c in rgb
    )


def luminance(h):
    r, g, b = (to_linear(int(h.lstrip("#")[i:i + 2], 16) / 255) for i in (0, 2, 4))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(x, y):
    a, b = sorted((luminance(x), luminance(y)), reverse=True)
    return (a + 0.05) / (b + 0.05)


def hue_delta(a, b):
    return (b - a + 180) % 360 - 180


def mix(x, y, t):
    xs = [int(x.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4)]
    ys = [int(y.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4)]
    return "#" + "".join(f"{round(p + (q - p) * t):02x}" for p, q in zip(xs, ys))


def file_hash(path):
    return hashlib.sha1(path.read_bytes()).hexdigest()


def analyse(path):
    cached = cache_dir / f"{file_hash(path)}-analysis-v{GENERATOR_VERSION}.json"
    if cached.exists():
        return json.loads(cached.read_text())
    image = Image.open(path).convert("RGB")
    image.thumbnail((160, 90))
    bins = [0.0] * 72
    total_l = total_a = total_b = total_c = 0.0
    pixels = list(image.get_flattened_data())
    for r, g, b in pixels:
        L, a, bb = rgb_to_oklab(r / 255, g / 255, b / 255)
        c = math.hypot(a, bb)
        total_l += L
        total_a += a
        total_b += bb
        total_c += c
        if c > 0.02:
            bins[int((math.degrees(math.atan2(bb, a)) % 360) // 5)] += c
    n = len(pixels)
    smooth = [sum(bins[(i + k) % 72] * w for k, w in ((-2, 1), (-1, 2), (0, 3), (1, 2), (2, 1))) / 9 for i in range(72)]
    top = max(smooth) or 1.0
    peaks = [
        i * 5 + 2.5
        for i in range(72)
        if smooth[i] >= 0.08 * top and smooth[i] >= smooth[i - 1] and smooth[i] >= smooth[(i + 1) % 72]
    ]
    result = {
        "lightness": total_l / n,
        "cast": [total_a / n, total_b / n],
        "chroma": total_c / n,
        "hues": [v / top for v in smooth],
        "peaks": peaks,
    }
    cache_dir.mkdir(parents=True, exist_ok=True)
    cached.write_text(json.dumps(result))
    return result


def hue_mass(stats, hue, width=25):
    return sum(w for i, w in enumerate(stats["hues"]) if abs(hue_delta(hue, i * 5 + 2.5)) <= width)


def earthy(hue, hues):
    lo, hi = hues
    if lo <= hue <= hi:
        return hue
    return lo if abs(hue_delta(hue, lo)) <= abs(hue_delta(hue, hi)) else hi


def shift_neutral(lch, stats, tone):
    L, C, h = lch
    cast_a, cast_b = stats["cast"]
    cast_c = math.hypot(cast_a, cast_b)
    cast_h = earthy(math.degrees(math.atan2(cast_b, cast_a)) % 360, tone["hues"])
    pull = min(1.0, cast_c / 0.02)
    scale = min(max(0.4 + cast_c / 0.03, 0.4), 1.0) * tone["warmth"]
    if L < 0.5:
        L += tone["lift"]
    return L, C * scale, (h + pull * hue_delta(h, cast_h)) % 360


def shift_accent(lch, stats, tone):
    L, C, h = lch
    near = [p for p in stats["peaks"] if abs(hue_delta(h, p)) <= 30]
    if near:
        target = min(near, key=lambda p: abs(hue_delta(h, p)))
        h = (h + 0.6 * hue_delta(h, target)) % 360
    muting = min(max(0.75 + stats["chroma"] * 3, 0.75), 1.0)
    return L, C * muting * tone["mute"], h


def ensure_contrast(colour, bg, ratio):
    L, C, h = hex_to_lch(colour)
    step = 0.01 if luminance(colour) > luminance(bg) else -0.01
    while contrast(colour, bg) < ratio and 0 < L < 1:
        L += step
        colour = lch_to_hex(L, C, h)
    return colour


def generate(path, mode):
    cached = cache_dir / f"{file_hash(path)}-{mode}-v{GENERATOR_VERSION}.json"
    if cached.exists():
        return json.loads(cached.read_text())
    stats = analyse(path)
    tone = TONES[mode]
    skeleton = config["skeletons"][tone["skeleton"]]
    roles = {"polarity": tone["polarity"]}
    for role, value in skeleton.items():
        if not value.startswith("#"):
            continue
        shift = shift_neutral if role in NEUTRAL_ROLES else shift_accent
        roles[role] = lch_to_hex(*shift(hex_to_lch(value), stats, tone))
    families = {name: roles[role] for name, role in FAMILY_ROLES.items()}
    ranked = sorted(families, key=lambda f: hue_mass(stats, hex_to_lch(families[f])[2]), reverse=True)
    if hue_mass(stats, hex_to_lch(families[ranked[0]])[2]) > 0.5:
        primary = ranked[0]
        primary_h = hex_to_lch(families[primary])[2]
        secondary = next(
            (f for f in ranked[1:] if abs(hue_delta(primary_h, hex_to_lch(families[f])[2])) >= 90),
            "blue",
        )
        roles["accent"] = families[primary]
        roles["accent-alt"] = families[secondary]
    roles["fg"] = ensure_contrast(roles["fg"], roles["bg"], 7)
    for role in ("accent", "accent-alt", "ok", "info", "warn", "error"):
        roles[role] = ensure_contrast(roles[role], roles["bg"], 3)
    roles["border-active"] = roles["accent"]
    cache_dir.mkdir(parents=True, exist_ok=True)
    cached.write_text(json.dumps(roles))
    return roles


def tertiary_of(roles):
    accent_h = hex_to_lch(roles["accent"])[2]
    alt_h = hex_to_lch(roles["accent-alt"])[2]
    candidates = [roles[r] for r in ("ansi13", "ansi14", "ansi11", "ansi9", "ansi10", "ansi12")]
    return max(
        candidates,
        key=lambda c: min(abs(hue_delta(accent_h, hex_to_lch(c)[2])), abs(hue_delta(alt_h, hex_to_lch(c)[2]))),
    )


def caelestia_colours(roles):
    light = roles["polarity"] == "light"
    bg, fg = roles["bg"], roles["fg"]
    outward = "#ffffff" if light else "#000000"

    def container(c):
        return mix(bg, c, 0.22 if light else 0.3)

    def on_container(c):
        return mix(c, fg, 0.55)

    def bright(c):
        L, C, h = hex_to_lch(c)
        return lch_to_hex(L + (-0.12 if light else 0.1), C, h)

    keyed = {
        "primary": roles["accent"],
        "secondary": roles["accent-alt"],
        "tertiary": tertiary_of(roles),
        "error": roles["error"],
        "success": roles["ok"],
    }
    out = {
        "primary_paletteKeyColor": keyed["primary"],
        "secondary_paletteKeyColor": keyed["secondary"],
        "tertiary_paletteKeyColor": keyed["tertiary"],
        "neutral_paletteKeyColor": roles["fg-faint"],
        "neutral_variant_paletteKeyColor": roles["fg-faint"],
        "background": bg,
        "onBackground": fg,
        "surface": bg,
        "surfaceDim": mix(bg, "#000000", 0.06),
        "surfaceBright": roles["overlay"],
        "surfaceContainerLowest": mix(bg, outward, 0.4 if light else 0.25),
        "surfaceContainerLow": roles["bg-alt"],
        "surfaceContainer": mix(roles["bg-alt"], roles["surface"], 0.5),
        "surfaceContainerHigh": roles["surface"],
        "surfaceContainerHighest": roles["overlay"],
        "onSurface": fg,
        "surfaceVariant": roles["surface"],
        "onSurfaceVariant": roles["fg-dim"],
        "inverseSurface": fg,
        "inverseOnSurface": bg,
        "outline": roles["fg-faint"],
        "outlineVariant": roles["overlay"],
        "shadow": "#000000",
        "scrim": "#000000",
        "surfaceTint": keyed["primary"],
        "inversePrimary": bright(keyed["primary"]),
        "text": fg,
        "subtext1": roles["fg-dim"],
        "subtext0": roles["fg-faint"],
        "overlay2": mix(roles["fg-faint"], roles["overlay"], 0.25),
        "overlay1": mix(roles["fg-faint"], roles["overlay"], 0.5),
        "overlay0": mix(roles["fg-faint"], roles["overlay"], 0.75),
        "surface2": roles["overlay"],
        "surface1": mix(roles["surface"], roles["overlay"], 0.5),
        "surface0": roles["surface"],
        "base": bg,
        "mantle": roles["bg-alt"],
        "crust": mix(bg, outward, 0.3),
        "red": roles["ansi9"],
        "maroon": mix(roles["ansi9"], roles["ansi13"], 0.3),
        "peach": roles["warn"] if light else mix(roles["ansi9"], roles["ansi11"], 0.5),
        "yellow": roles["ansi11"],
        "green": roles["ansi10"],
        "teal": roles["ansi14"],
        "sky": mix(roles["ansi12"], roles["ansi14"], 0.5),
        "sapphire": mix(roles["ansi12"], roles["ansi14"], 0.25),
        "blue": roles["ansi12"],
        "lavender": mix(roles["ansi12"], roles["ansi13"], 0.5),
        "mauve": roles["ansi13"],
        "pink": mix(roles["ansi13"], fg, 0.3),
        "flamingo": mix(roles["ansi9"], fg, 0.4),
        "rosewater": mix(roles["ansi9"], fg, 0.6),
    }
    for name, colour in keyed.items():
        cap = name[0].upper() + name[1:]
        out[name] = colour
        out[f"on{cap}"] = bg
        out[f"{name}Container"] = container(colour)
        out[f"on{cap}Container"] = on_container(colour)
        if name not in ("error", "success"):
            out[f"{name}Fixed"] = container(colour)
            out[f"{name}FixedDim"] = mix(bg, colour, 0.4)
            out[f"on{cap}Fixed"] = fg
            out[f"on{cap}FixedVariant"] = on_container(colour)
    for name, role in (
        ("klink", "ansi12"),
        ("kvisited", "ansi13"),
        ("knegative", "ansi9"),
        ("kneutral", "ansi11"),
        ("kpositive", "ansi10"),
    ):
        out[name] = roles[role]
        out[f"{name}Selection"] = roles[role]
    for i in range(16):
        out[f"term{i}"] = roles[f"ansi{i}"]
    return {k: v.lstrip("#") for k, v in out.items()}


def cast_of(stats):
    a, b = stats["cast"]
    return math.hypot(a, b), math.degrees(math.atan2(b, a)) % 360


def classify(path):
    if path.parent.name in TONES:
        return path.parent.name
    stats = analyse(path)
    chroma, hue = cast_of(stats)
    lo, hi = DUSK_CAST_HUES
    if chroma >= DUSK_CAST_CHROMA and lo <= hue <= hi:
        return "dusk"
    return "light" if stats["lightness"] >= DARK_LIGHTNESS else "dark"


def wallpapers():
    root = Path(config["wallpaperDir"]).expanduser()
    return sorted(p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in IMAGE_SUFFIXES)


def parse_clock(s):
    return time.fromisoformat(s)


def mode_at(now):
    span = timedelta(minutes=config["duskMinutes"])
    dark_by = datetime.combine(now.date(), parse_clock(config["darkBy"]), now.tzinfo)
    dusk_from, dark_from = dark_by - 2 * span, dark_by
    try:
        sunset = sun(Observer(config["latitude"], config["longitude"]), date=now.date(), tzinfo=now.tzinfo)["sunset"]
        dusk_from, dark_from = min(dusk_from, sunset - span), min(dark_from, sunset + span)
    except ValueError:
        pass
    if now >= dark_from or now.time() < parse_clock(config["lightAt"]):
        return "dark"
    return "dusk" if now >= dusk_from else "light"


def read_state():
    try:
        return json.loads(state_file.read_text())
    except (OSError, ValueError):
        return {}


def write_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def caelestia_scheme():
    try:
        return json.loads(Path(config["caelestiaScheme"]).read_text())
    except (OSError, ValueError):
        return {}


def apply(path, mode):
    roles = generate(path, mode)
    write_atomic(Path(config["palettePath"]), json.dumps(roles))
    subprocess.run([config["themeApply"]], check=False)
    polarity = roles["polarity"]
    colours = caelestia_colours(roles)
    write_atomic(
        Path(config["schemeRoot"]) / mode / f"{polarity}.txt",
        "".join(f"{k} {v}\n" for k, v in colours.items()),
    )
    current = caelestia_scheme()
    if (current.get("name"), current.get("flavour"), current.get("mode")) != ("wallpaper", mode, polarity):
        subprocess.run(
            [config["caelestia"], "scheme", "set", "-n", "wallpaper", "-f", mode, "-m", polarity], check=True
        )
    subprocess.run([config["caelestia"], "wallpaper", "-f", str(path), "--no-smart"], check=True)
    write_atomic(state_file, json.dumps({"mode": mode, "wallpaper": str(path)}))


def cmd_next(_):
    mode = mode_at(datetime.now().astimezone())
    current = read_state().get("wallpaper")
    classes = {p: classify(p) for p in wallpapers()}
    pool = next(
        ([p for p, c in classes.items() if c == pool_mode] for pool_mode in FALLBACK_POOLS[mode] if pool_mode in classes.values()),
        list(classes),
    )
    if not pool:
        sys.exit("wallpaper-theme: no wallpapers in " + config["wallpaperDir"])
    choices = [p for p in pool if str(p) != current] or pool
    apply(random.choice(choices), mode)


def cmd_sync(_):
    state = read_state()
    mode = mode_at(datetime.now().astimezone())
    shown = Path(config["caelestiaWallpaper"]).read_text().strip() if Path(config["caelestiaWallpaper"]).exists() else ""
    if state.get("mode") != mode or state.get("wallpaper") != shown or not Path(shown).exists():
        cmd_next(None)


def cmd_mode(args):
    now = datetime.fromisoformat(args.now) if args.now else datetime.now()
    print(mode_at(now.astimezone() if now.tzinfo is None else now))


def cmd_list(_):
    for p in wallpapers():
        stats = analyse(p)
        chroma, hue = cast_of(stats)
        print(f"{classify(p):5}  L {stats['lightness']:.3f}  cast {chroma:.3f} @ {hue:3.0f}  {p}")


def cmd_palette(args):
    print(json.dumps(generate(Path(args.image).resolve(), args.mode), indent=2))


def main():
    parser = argparse.ArgumentParser(prog="wallpaper-theme")
    sub = parser.add_subparsers(required=True)
    sub.add_parser("next").set_defaults(func=cmd_next)
    sub.add_parser("sync").set_defaults(func=cmd_sync)
    sub.add_parser("list").set_defaults(func=cmd_list)
    mode = sub.add_parser("mode")
    mode.add_argument("--now")
    mode.set_defaults(func=cmd_mode)
    palette = sub.add_parser("palette")
    palette.add_argument("image")
    palette.add_argument("mode", choices=tuple(TONES))
    palette.set_defaults(func=cmd_palette)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

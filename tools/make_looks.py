"""Generates the film look colour cubes in App/Looks and a contact sheet to judge them by eye.

Usage: python tools/make_looks.py [photo ...] [--sheet out.png]
"""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

CUBE_SIZE = 33
OUTPUT = Path(__file__).resolve().parent.parent / "App" / "Looks"


def curve(points):
    """Monotone cubic interpolation (Fritsch-Carlson) through (input, output) points."""
    xs = np.array([p[0] for p in points], dtype=np.float64)
    ys = np.array([p[1] for p in points], dtype=np.float64)
    h = np.diff(xs)
    delta = np.diff(ys) / h
    m = np.zeros_like(ys)
    m[1:-1] = (delta[:-1] + delta[1:]) / 2
    m[0], m[-1] = delta[0], delta[-1]
    for i, d in enumerate(delta):
        if d == 0:
            m[i] = m[i + 1] = 0
        else:
            a, b = m[i] / d, m[i + 1] / d
            s = a * a + b * b
            if s > 9:
                t = 3 / np.sqrt(s)
                m[i], m[i + 1] = t * a * d, t * b * d

    def apply(values):
        v = np.clip(values, 0, 1)
        i = np.clip(np.searchsorted(xs, v) - 1, 0, len(h) - 1)
        t = (v - xs[i]) / h[i]
        return (
            (2 * t**3 - 3 * t**2 + 1) * ys[i]
            + (t**3 - 2 * t**2 + t) * h[i] * m[i]
            + (-2 * t**3 + 3 * t**2) * ys[i + 1]
            + (t**3 - t**2) * h[i] * m[i + 1]
        )

    return apply


LMS_FROM_RGB = np.array([
    [0.4122214708, 0.5363325363, 0.0514459929],
    [0.2119034982, 0.6806995451, 0.1073969566],
    [0.0883024619, 0.2817188376, 0.6299787005],
])
LAB_FROM_LMS = np.array([
    [0.2104542553, 0.7936177850, -0.0040720468],
    [1.9779984951, -2.4285922050, 0.4505937099],
    [0.0259040371, 0.7827717662, -0.8086757660],
])
RGB_FROM_LMS = np.linalg.inv(LMS_FROM_RGB)
LMS_FROM_LAB = np.linalg.inv(LAB_FROM_LMS)
MID_GREY = 0.18
NEUTRAL_LAYERS = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
NEUTRAL_WIDTH = 0.026


def to_linear(v):
    v = np.clip(v, 0, 1)
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def to_encoded(v):
    v = np.clip(v, 0, 1)
    return np.where(v <= 0.0031308, v * 12.92, 1.055 * v ** (1 / 2.4) - 0.055)


def oklab(linear):
    return np.cbrt(linear @ LMS_FROM_RGB.T) @ LAB_FROM_LMS.T


def linear_from_oklab(lab):
    return (lab @ LMS_FROM_LAB.T) ** 3 @ RGB_FROM_LMS.T


def polar(lab):
    return np.hypot(lab[..., 1], lab[..., 2]), np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360


def from_polar(L, chroma, hue):
    return np.stack([L, chroma * np.cos(np.radians(hue)), chroma * np.sin(np.radians(hue))], axis=-1)


def bump(value, center, width):
    return np.exp(-0.5 * ((value - center) / width) ** 2)


def hue_bump(hue, center, width):
    return bump((hue - center + 180) % 360 - 180, 0, width)


def expose(rgb, layers, couplers):
    """Film-like exposure: overlapping layer sensitivities, then coupler contrast between layers.

    Couplers push each layer away from the others in log exposure, most in the midtones,
    so saturation peaks there and falls away towards black and white. Neutrals are untouched.
    """
    linear = np.clip(to_linear(rgb) @ np.array(layers).T, 0, 1)
    stops = np.log2(linear + 0.01)
    level = stops.mean(axis=-1, keepdims=True)
    strength = couplers * bump(level, np.log2(MID_GREY + 0.01), 2.4)
    stops = stops + strength * (stops - level)
    return to_encoded(np.clip(2 ** stops - 0.01, 0, 1))


def print_tone(encoded, knots, keep_hue):
    """A tone curve per layer. `keep_hue` takes back part of the hue skew per-layer curves cause."""
    before = oklab(to_linear(encoded))
    after = oklab(to_linear(curve(knots)(encoded)))
    ratio = (polar(after)[0] / (polar(before)[0] + 1e-4))[..., None]
    after[..., 1:] += keep_hue * (before[..., 1:] * ratio - after[..., 1:])
    return after


def colour_map(lab, table, chroma_curve, density):
    """Hue-specific shifts. Each row is (hue, width, hue shift, chroma scale, darkening per chroma)."""
    L = lab[..., 0]
    chroma, hue = polar(lab)
    settled = chroma**2 / (chroma**2 + 0.018**2)
    shift, scale, darken = np.zeros_like(L), np.ones_like(L), np.full_like(L, density)
    for center, width, turn, multiply, deepen in table:
        weight = hue_bump(hue, center, width)
        shift += weight * turn
        scale += weight * (multiply - 1)
        darken += weight * deepen
    # Density eases off at high chroma so vivid ramps keep rising in lightness.
    return from_polar(L - darken * chroma / (1 + 2.5 * chroma), chroma * scale * curve(chroma_curve)(L), hue + shift * settled)


def hold_neutrals(lab, source):
    """Gives near-neutrals back their own colour, so contrast and couplers can't stain walls and white lines."""
    weight = bump(polar(source)[0], 0, NEUTRAL_WIDTH)[..., None]
    held = lab.copy()
    held[..., 1:] += weight * (source[..., 1:] - lab[..., 1:])
    return held


def tint(lab, tint_a, tint_b):
    """Colour of the neutral axis by lightness: film's crossover between layers."""
    return np.stack([
        lab[..., 0],
        lab[..., 1] + curve(tint_a)(lab[..., 0]),
        lab[..., 2] + curve(tint_b)(lab[..., 0]),
    ], axis=-1)


def protect_skin(lab, source, amount, saturation, center):
    """Pulls skin into a narrow band of warm hues around `center`, keeping the look's lightness and its own chroma."""
    chroma, hue = polar(source)
    weight = (
        amount
        * hue_bump(hue, 53, 24)
        * np.clip(chroma / 0.022, 0, 1) ** 2
        * np.clip((0.17 - chroma) / 0.06, 0, 1) ** 2
        * np.clip(source[..., 0] / 0.2, 0, 1) ** 2
        * np.clip((1 - source[..., 0]) / 0.1, 0, 1) ** 2
    )
    # A darker rendering carries less chroma, so scale with the lightness the look gave it.
    scaled = chroma * saturation * np.clip(lab[..., 0] / np.maximum(source[..., 0], 0.05), 0.6, 1.1) ** 0.7
    held = from_polar(lab[..., 0], scaled, center + 0.7 * ((hue - 53 + 180) % 360 - 180))
    return lab + weight[..., None] * (held - lab)


def finish(lab, soft=0.8):
    """Compresses colour smoothly towards the sRGB gamut boundary along its own hue, then encodes."""
    linear = linear_from_oklab(lab)
    grey = np.clip(lab[..., :1], 0, 1) ** 3
    offset = linear - grey
    # How far each colour sits towards the gamut edge: 1 means on it.
    reach = np.maximum(offset / np.maximum(1 - grey, 1e-6), -offset / np.maximum(grey, 1e-6)).max(axis=-1, keepdims=True)
    room = 1 - soft
    held = np.where(reach > soft, soft + room * np.tanh((reach - soft) / room), reach)
    return to_encoded(grey + offset * held / np.maximum(reach, 1e-6))


def film(rgb, layers, couplers, tone, keep_hue, table, chroma_curve, density, tint_a, tint_b, skin_hue, skin_saturation, skin=0.85):
    source = oklab(to_linear(rgb))
    lab = colour_map(print_tone(expose(rgb, layers, couplers), tone, keep_hue), table, chroma_curve, density)
    return finish(protect_skin(tint(hold_neutrals(lab, source), tint_a, tint_b), source, skin, skin_saturation, skin_hue))


def honey(rgb):
    """Warm colour negative after Portra and Gold: golden highlights, amber skin, olive greens, soft brown blacks."""
    return film(
        rgb,
        layers=NEUTRAL_LAYERS,
        couplers=0.15,
        tone=[(0, 0.035), (0.1, 0.085), (0.25, 0.215), (0.5, 0.51), (0.75, 0.80), (0.9, 0.92), (1, 0.965)],
        keep_hue=0.25,
        table=[
            (29, 26, 4, 1.05, 0.10),     # reds lean orange
            (65, 22, 0, 1.12, 0.0),      # oranges glow
            (108, 26, -6, 1.05, 0.0),    # yellows lean golden
            (135, 28, 0, 1.10, -0.12),   # greens lean olive through the warm cast but stay alive
            (205, 30, 4, 0.85, 0.05),    # cyan to a quiet teal
            (255, 28, -6, 0.95, 0.20),   # blues deepen and quieten
        ],
        chroma_curve=[(0, 0.85), (0.3, 1.05), (0.6, 1.10), (0.85, 0.95), (1, 0.6)],
        density=0.12,
        tint_a=[(0, 0.0), (0.12, 0.005), (0.6, 0.010), (0.9, 0.008), (1, 0.003)],
        tint_b=[(0, 0.0), (0.12, 0.006), (0.3, 0.012), (0.6, 0.020), (0.9, 0.026), (1, 0.012)],
        skin_hue=58,
        skin_saturation=1.1,
    )


def noon(rgb):
    """Clean bright negative after overexposed Portra 160: open midtones, fresh colour, true whites, firm blacks."""
    return film(
        rgb,
        layers=NEUTRAL_LAYERS,
        couplers=0.12,
        tone=[(0, 0.01), (0.1, 0.09), (0.25, 0.31), (0.5, 0.63), (0.75, 0.87), (0.9, 0.96), (1, 1)],
        keep_hue=0.4,
        table=[
            (29, 26, -2, 1.05, 0.05),    # reds stay clean
            (108, 26, -2, 1.0, 0.0),     # yellows hold
            (135, 30, -4, 1.0, 0.05),    # greens stay fresh
            (205, 30, 12, 1.05, 0.05),   # phone cyan turns to true sky blue
            (255, 28, -4, 1.10, 0.12),   # skies clear
        ],
        chroma_curve=[(0, 0.85), (0.3, 1.15), (0.6, 1.15), (0.85, 0.95), (1, 0.55)],
        density=0.08,
        tint_a=[(0, 0.0), (1, 0.0)],
        tint_b=[(0, 0.0), (0.2, -0.002), (0.5, 0.002), (0.9, 0.004), (1, 0.001)],
        skin_hue=55,
        skin_saturation=1.02,
    )


def mist(rgb):
    """Cool soft pastel after Fuji 400H: slate shadows, mint greens, powder skies, gentle pink skin."""
    return film(
        rgb,
        layers=[[0.94, 0.05, 0.01], [0.01, 0.95, 0.04], [0.005, 0.045, 0.95]],
        couplers=0.05,
        tone=[(0, 0.07), (0.1, 0.125), (0.25, 0.29), (0.5, 0.58), (0.75, 0.83), (0.9, 0.935), (1, 0.98)],
        keep_hue=0.5,
        table=[
            (20, 24, -8, 0.90, 0.0),     # reds lean rose
            (108, 26, 8, 0.85, 0.0),     # yellows lean lemon
            (135, 30, 22, 0.75, -0.05),  # greens to a bright mint
            (205, 30, -8, 1.10, 0.0),    # cyan leans to sea-glass
            (255, 28, -14, 1.0, 0.05),   # blues to powder
        ],
        chroma_curve=[(0, 0.75), (0.3, 0.92), (0.6, 0.98), (0.85, 0.85), (1, 0.5)],
        density=0.0,
        tint_a=[(0, -0.010), (0.3, -0.008), (0.6, -0.005), (1, 0.0)],
        tint_b=[(0, -0.018), (0.3, -0.018), (0.6, -0.012), (0.85, -0.006), (1, -0.002)],
        skin_hue=50,
        skin_saturation=0.92,
    )


def reef(rgb):
    """Saturated slide film after Velvia: deep cobalt skies, emerald greens, crimson reds, violet-black shadows."""
    return film(
        rgb,
        layers=NEUTRAL_LAYERS,
        couplers=0.25,
        tone=[(0, 0.0), (0.1, 0.045), (0.25, 0.17), (0.5, 0.47), (0.75, 0.80), (0.9, 0.94), (1, 0.99)],
        keep_hue=0.2,
        table=[
            (29, 26, -3, 1.18, 0.20),    # reds to crimson
            (108, 26, 0, 1.10, 0.05),    # yellows ripen
            (135, 30, 10, 1.25, 0.05),   # greens to emerald
            (205, 32, 22, 1.20, 0.35),   # cyan to deep blue
            (255, 30, -5, 1.20, 0.35),   # blues to cobalt
            (330, 30, 0, 1.20, 0.20),    # magentas deepen
        ],
        chroma_curve=[(0, 0.85), (0.3, 1.10), (0.6, 1.20), (0.85, 0.95), (1, 0.55)],
        density=0.20,
        tint_a=[(0, 0.0), (0.15, 0.008), (0.35, 0.007), (0.6, 0.003), (1, 0.0)],
        tint_b=[(0, 0.0), (0.15, -0.016), (0.35, -0.014), (0.6, -0.004), (0.85, 0.002), (1, 0.002)],
        skin_hue=52,
        skin_saturation=0.95,
    )


def lantern(rgb):
    """Tungsten cine stock after Vision3 500T: dense teal shadows, ember highlights, bottle greens."""
    return film(
        rgb,
        layers=NEUTRAL_LAYERS,
        couplers=0.2,
        tone=[(0, 0.015), (0.1, 0.05), (0.25, 0.165), (0.5, 0.43), (0.75, 0.74), (0.9, 0.89), (1, 0.955)],
        keep_hue=0.5,
        table=[
            (29, 26, 6, 1.10, 0.15),     # reds to ember
            (65, 25, -4, 1.20, 0.0),     # oranges glow
            (108, 26, -22, 0.85, 0.05),  # yellows to amber
            (135, 32, 30, 0.85, 0.05),   # greens to bottle teal
            (195, 30, 10, 1.20, 0.10),   # cyan deepens and holds against the warmth
            (255, 35, -22, 0.85, 0.20),  # blues to teal
        ],
        chroma_curve=[(0, 0.7), (0.2, 0.95), (0.55, 1.05), (0.85, 0.85), (1, 0.5)],
        density=0.12,
        tint_a=[(0, 0.0), (0.12, -0.005), (0.3, -0.018), (0.5, -0.004), (0.8, 0.012), (1, 0.004)],
        tint_b=[(0, 0.0), (0.12, -0.010), (0.3, -0.026), (0.5, -0.006), (0.8, 0.026), (1, 0.010)],
        skin_hue=58,
        skin_saturation=1.05,
    )


def attic(rgb):
    """Faded vintage print from an aged colour album: plum blacks, cream whites, khaki greens, dusty teal skies."""
    return film(
        rgb,
        layers=NEUTRAL_LAYERS,
        couplers=0.1,
        tone=[(0, 0.105), (0.1, 0.14), (0.25, 0.24), (0.5, 0.50), (0.75, 0.76), (0.9, 0.875), (1, 0.93)],
        keep_hue=0.4,
        table=[
            (29, 26, 8, 0.95, 0.10),     # reds to brick
            (108, 28, -12, 0.90, 0.0),   # yellows to mustard
            (135, 30, -20, 0.75, 0.05),  # greens to khaki
            (205, 30, -6, 0.85, 0.05),   # cyan fades
            (255, 30, -16, 0.80, 0.10),  # blues to dusty teal
            (330, 30, -14, 0.80, 0.0),   # magentas to rose
        ],
        chroma_curve=[(0, 0.8), (0.3, 0.95), (0.6, 1.0), (0.85, 0.8), (1, 0.45)],
        density=0.05,
        tint_a=[(0, 0.014), (0.3, 0.011), (0.6, 0.008), (1, 0.004)],
        tint_b=[(0, 0.004), (0.3, 0.004), (0.6, 0.012), (1, 0.024)],
        skin_hue=55,
        skin_saturation=0.95,
    )


def riot(rgb):
    """Punchy high-contrast colour after pushed consumer film and direct flash: hard blacks, hot reds, bright whites."""
    return film(
        rgb,
        layers=NEUTRAL_LAYERS,
        couplers=0.3,
        tone=[(0, 0), (0.1, 0.025), (0.25, 0.135), (0.5, 0.50), (0.75, 0.86), (0.9, 0.97), (1, 1)],
        keep_hue=0.1,
        table=[
            (29, 26, 6, 1.25, 0.12),     # reds to scarlet
            (65, 25, 0, 1.20, 0.0),      # oranges burn
            (108, 26, 0, 1.15, 0.0),     # yellows blaze
            (135, 30, -10, 1.20, 0.05),  # greens to grass
            (205, 30, 10, 0.85, 0.0),    # cyan stays light
            (255, 30, -4, 1.10, 0.20),   # blues to electric
        ],
        chroma_curve=[(0, 0.85), (0.3, 1.15), (0.6, 1.20), (0.85, 0.95), (1, 0.5)],
        density=0.12,
        tint_a=[(0, 0.0), (0.15, -0.002), (0.6, 0.002), (0.85, 0.002), (1, 0.0)],
        tint_b=[(0, 0.0), (0.15, -0.008), (0.35, -0.004), (0.6, 0.008), (0.85, 0.012), (1, 0.002)],
        skin_hue=55,
        skin_saturation=0.95,
    )


def soot(rgb):
    """Black and white after pushed Tri-X with an orange filter: inky blacks, bright midtones, a long hard shoulder."""
    mono = to_encoded(to_linear(rgb) @ np.array([0.46, 0.50, 0.04]))
    y = curve([(0, 0), (0.1, 0.02), (0.25, 0.13), (0.5, 0.49), (0.75, 0.84), (0.9, 0.96), (1, 1)])(mono)
    return np.stack([y, y, y], axis=-1)


LOOKS = {
    "honey": honey,
    "noon": noon,
    "mist": mist,
    "reef": reef,
    "lantern": lantern,
    "attic": attic,
    "riot": riot,
    "soot": soot,
}


def build_cube(look):
    axis = np.linspace(0, 1, CUBE_SIZE)
    b, g, r = np.meshgrid(axis, axis, axis, indexing="ij")
    rgb = np.stack([r, g, b], axis=-1).astype(np.float64)
    return np.clip(look(rgb), 0, 1)


def apply_cube(image, cube):
    """Trilinear lookup, matching what Core Image does with the same cube."""
    position = image * (CUBE_SIZE - 1)
    low = np.clip(np.floor(position).astype(int), 0, CUBE_SIZE - 2)
    t = position - low
    r, g, b = low[..., 0], low[..., 1], low[..., 2]
    tr, tg, tb = t[..., :1], t[..., 1:2], t[..., 2:]
    c = lambda db, dg, dr: cube[b + db, g + dg, r + dr]
    return (
        (c(0, 0, 0) * (1 - tr) + c(0, 0, 1) * tr) * (1 - tg) * (1 - tb)
        + (c(0, 1, 0) * (1 - tr) + c(0, 1, 1) * tr) * tg * (1 - tb)
        + (c(1, 0, 0) * (1 - tr) + c(1, 0, 1) * tr) * (1 - tg) * tb
        + (c(1, 1, 0) * (1 - tr) + c(1, 1, 1) * tr) * tg * tb
    )


def contact_sheet(photos, cubes, path, cell_width=300):
    rows = []
    for photo in photos:
        source = Image.open(photo).convert("RGB")
        scale = cell_width / source.width
        source = source.resize((cell_width, round(source.height * scale)), Image.LANCZOS)
        rows.append(np.asarray(source, dtype=np.float64) / 255)

    columns = ["natural", *cubes]
    width = len(columns) * (cell_width + 8) + 8
    height = sum(row.shape[0] + 30 for row in rows) + 8
    sheet = Image.new("RGB", (width, height), (16, 16, 15))
    draw = ImageDraw.Draw(sheet)
    y = 8
    for row in rows:
        for i, name in enumerate(columns):
            result = row if name == "natural" else apply_cube(row, cubes[name])
            x = 8 + i * (cell_width + 8)
            sheet.paste(Image.fromarray((np.clip(result, 0, 1) * 255).astype(np.uint8)), (x, y))
            draw.text((x, y + row.shape[0] + 6), name, fill=(235, 232, 225))
        y += row.shape[0] + 30
    sheet.save(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("photos", nargs="*")
    parser.add_argument("--sheet")
    args = parser.parse_args()

    OUTPUT.mkdir(parents=True, exist_ok=True)
    cubes = {}
    for name, look in LOOKS.items():
        cube = build_cube(look)
        cubes[name] = cube
        encoded = np.round(cube * 65535).astype("<u2")
        (OUTPUT / f"{name}.lut").write_bytes(encoded.tobytes())

    if args.sheet and args.photos:
        contact_sheet(args.photos, cubes, args.sheet)


if __name__ == "__main__":
    main()

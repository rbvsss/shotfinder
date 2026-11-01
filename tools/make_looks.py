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
    return from_polar(L - darken * chroma, chroma * scale * curve(chroma_curve)(L), hue + shift * settled)


def tint(lab, tint_a, tint_b):
    """Colour of the neutral axis by lightness: film's crossover between layers."""
    return np.stack([
        lab[..., 0],
        lab[..., 1] + curve(tint_a)(lab[..., 0]),
        lab[..., 2] + curve(tint_b)(lab[..., 0]),
    ], axis=-1)


def protect_skin(lab, source, amount, saturation, center=58.0):
    """Holds skin to a narrow band of warm hues near its original chroma, whatever the look does."""
    chroma, hue = polar(source)
    weight = (
        amount
        * hue_bump(hue, center, 22)
        * np.clip(chroma / 0.025, 0, 1) ** 2
        * np.clip((0.20 - chroma) / 0.07, 0, 1) ** 2
        * bump(source[..., 0], 0.62, 0.32)
    )
    # A darker rendering carries less chroma, so scale with the lightness the look gave it.
    scaled = chroma * saturation * np.clip(lab[..., 0] / np.maximum(source[..., 0], 0.05), 0.6, 1.1) ** 0.7
    held = from_polar(lab[..., 0], scaled, center + 0.8 * ((hue - center + 180) % 360 - 180))
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


def film(rgb, layers, couplers, tone, keep_hue, table, chroma_curve, density, tint_a, tint_b, skin=0.8, skin_saturation=0.95):
    source = oklab(to_linear(rgb))
    lab = colour_map(print_tone(expose(rgb, layers, couplers), tone, keep_hue), table, chroma_curve, density)
    return finish(protect_skin(tint(lab, tint_a, tint_b), source, skin, skin_saturation))


def kiln(rgb):
    """Warm colour negative after Portra: soft, honeyed, peachy skin, olive greens."""
    return film(
        rgb,
        layers=[[0.94, 0.05, 0.01], [0.012, 0.968, 0.02], [0.005, 0.055, 0.94]],
        couplers=0.10,
        tone=[(0, 0.032), (0.1, 0.095), (0.25, 0.245), (0.5, 0.525), (0.75, 0.775), (0.9, 0.900), (1, 0.962)],
        keep_hue=0.35,
        table=[
            (29, 26, 2, 0.90, 0.05),     # reds lean slightly to orange
            (108, 26, -6, 0.98, 0.0),    # yellows lean golden
            (142, 28, -11, 0.80, 0.08),  # greens to olive
            (205, 30, 10, 0.80, 0.03),   # cyan towards a quieter teal-blue
            (255, 28, -6, 0.88, 0.10),   # blues deepen and quieten
        ],
        chroma_curve=[(0, 0.75), (0.3, 0.92), (0.6, 1.0), (0.85, 0.88), (1, 0.6)],
        density=0.06,
        tint_a=[(0, 0.004), (0.3, 0.003), (0.6, 0.002), (1, 0.003)],
        tint_b=[(0, 0.006), (0.3, 0.005), (0.6, 0.007), (1, 0.012)],
    )


def fjord(rgb):
    """Cool and airy after Fuji Pro: lifted slate shadows, mint greens, soft pastel colour."""
    return film(
        rgb,
        layers=[[0.94, 0.05, 0.01], [0.01, 0.95, 0.04], [0.005, 0.045, 0.95]],
        couplers=0.06,
        tone=[(0, 0.052), (0.1, 0.115), (0.25, 0.255), (0.5, 0.525), (0.75, 0.770), (0.9, 0.885), (1, 0.948)],
        keep_hue=0.5,
        table=[
            (20, 24, -8, 0.88, 0.0),     # reds lean rose
            (108, 26, 8, 0.86, 0.0),     # yellows lean lemon
            (142, 30, 14, 0.74, 0.03),   # greens to mint
            (205, 30, 10, 0.96, 0.0),    # cyan holds
            (255, 28, -8, 0.90, 0.04),   # blues to cyan
        ],
        chroma_curve=[(0, 0.6), (0.3, 0.8), (0.6, 0.88), (0.85, 0.78), (1, 0.5)],
        density=0.0,
        tint_a=[(0, -0.004), (0.3, -0.005), (0.6, -0.002), (1, -0.001)],
        tint_b=[(0, -0.011), (0.3, -0.012), (0.6, -0.005), (1, -0.002)],
        skin_saturation=1.0,
    )


def cinder(rgb):
    """Low and dense after tungsten cine stock: inky teal shadows, warm highlights, deep colour."""
    return film(
        rgb,
        layers=[[0.95, 0.04, 0.01], [0.015, 0.965, 0.02], [0.01, 0.06, 0.93]],
        couplers=0.08,
        tone=[(0, 0.012), (0.1, 0.040), (0.25, 0.150), (0.5, 0.440), (0.75, 0.750), (0.9, 0.890), (1, 0.950)],
        keep_hue=0.5,
        table=[
            (29, 26, 2, 0.92, 0.06),      # reds toward ember
            (70, 26, -2, 0.92, 0.0),      # oranges hold
            (142, 30, 10, 0.66, 0.22),    # greens deep and bottle-dark
            (205, 30, -3, 0.72, 0.12),    # cyan deepens
            (255, 30, -10, 0.76, 0.16),   # blues toward teal
        ],
        chroma_curve=[(0, 0.6), (0.2, 0.84), (0.55, 0.90), (0.85, 0.76), (1, 0.5)],
        density=0.10,
        tint_a=[(0, -0.006), (0.25, -0.008), (0.55, 0.0), (0.8, 0.005), (1, 0.004)],
        tint_b=[(0, -0.008), (0.25, -0.010), (0.55, 0.002), (0.8, 0.015), (1, 0.012)],
        skin_saturation=1.0,
    )


def salt(rgb):
    """Pale overexposed negative: bright open midtones, chalky colour, clean whites."""
    return film(
        rgb,
        layers=[[0.88, 0.09, 0.03], [0.04, 0.90, 0.06], [0.02, 0.08, 0.90]],
        couplers=0.0,
        tone=[(0, 0.048), (0.1, 0.150), (0.25, 0.345), (0.5, 0.650), (0.75, 0.860), (0.9, 0.948), (1, 0.985)],
        keep_hue=0.7,
        table=[
            (29, 26, 6, 0.90, 0.0),
            (108, 28, 0, 0.90, 0.0),
            (142, 30, -4, 0.76, 0.0),
            (255, 30, 4, 0.80, 0.0),
        ],
        chroma_curve=[(0, 0.7), (0.3, 0.88), (0.6, 0.86), (0.85, 0.76), (1, 0.45)],
        density=0.0,
        tint_a=[(0, 0.004), (0.3, 0.002), (1, 0.0)],
        tint_b=[(0, 0.004), (0.3, 0.004), (1, 0.0)],
        skin_saturation=0.90,
    )


def graphite(rgb):
    """Black and white after Tri-X with a red-filter lean: long toe, bright midtones, dark skies."""
    mono = to_encoded(to_linear(rgb) @ np.array([0.36, 0.56, 0.08]))
    y = curve([(0, 0.016), (0.1, 0.055), (0.25, 0.195), (0.5, 0.530), (0.75, 0.815), (0.9, 0.930), (1, 0.978)])(mono)
    return np.stack([y, y, y], axis=-1)


LOOKS = {"kiln": kiln, "fjord": fjord, "cinder": cinder, "salt": salt, "graphite": graphite}


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

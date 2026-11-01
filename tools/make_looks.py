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


def luma(rgb):
    return rgb @ np.array([0.2126, 0.7152, 0.0722])


def hue_weight(rgb, center, width):
    """How close each colour's hue is to `center` degrees, from 0 to 1."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    hue = np.degrees(np.arctan2(np.sqrt(3) * (g - b), 2 * r - g - b)) % 360
    distance = np.abs((hue - center + 180) % 360 - 180)
    chroma = rgb.max(axis=-1) - rgb.min(axis=-1)
    return np.clip(1 - distance / width, 0, 1) ** 2 * np.clip(chroma * 6, 0, 1)


def split_tone(rgb, shadows, highlights):
    """Tints dark tones towards `shadows` and light tones towards `highlights`."""
    y = luma(rgb)[..., None]
    low = np.clip(1 - y * 2.2, 0, 1) ** 1.5
    high = np.clip(y * 1.8 - 0.8, 0, 1) ** 1.2
    return rgb + low * np.array(shadows) + high * np.array(highlights)


def mix_saturation(rgb, amount):
    y = luma(rgb)[..., None]
    return y + (rgb - y) * amount


def shift_towards(rgb, weight, target, amount):
    return rgb + weight[..., None] * amount * (np.array(target) - rgb)


def kiln(rgb):
    """Warm colour negative: soft highlights, honeyed midtones, muted greens."""
    r = curve([(0, 0.035), (0.25, 0.25), (0.55, 0.59), (0.85, 0.87), (1, 0.97)])
    g = curve([(0, 0.03), (0.25, 0.235), (0.55, 0.57), (0.85, 0.855), (1, 0.96)])
    b = curve([(0, 0.04), (0.25, 0.225), (0.55, 0.535), (0.85, 0.825), (1, 0.935)])
    out = np.stack([r(rgb[..., 0]), g(rgb[..., 1]), b(rgb[..., 2])], axis=-1)
    out = shift_towards(out, hue_weight(rgb, 110, 60), [0.47, 0.50, 0.28], 0.28)
    return mix_saturation(out, 0.96)


def fjord(rgb):
    """Cool and faded: lifted blacks, airy skies, slate-blue shadows."""
    tone = curve([(0, 0.07), (0.22, 0.225), (0.55, 0.57), (0.85, 0.85), (1, 0.945)])
    out = tone(rgb)
    out = split_tone(out, [-0.012, 0.004, 0.022], [-0.004, 0.004, 0.012])
    out = shift_towards(out, hue_weight(rgb, 110, 70), [0.34, 0.45, 0.36], 0.3)
    return mix_saturation(out, 0.82)


def cinder(rgb):
    """Low and moody: deep shadows, deep greens, warmth held in the highlights."""
    tone = curve([(0, 0.012), (0.25, 0.14), (0.55, 0.43), (0.85, 0.77), (1, 0.93)])
    out = tone(rgb)
    out = split_tone(out, [-0.012, 0.006, 0.012], [0.018, 0.006, -0.018])
    out = shift_towards(out, hue_weight(rgb, 110, 70), [0.16, 0.30, 0.22], 0.34)
    return mix_saturation(out, 0.92)


def salt(rgb):
    """Bright and pale: open midtones, gentle contrast, clean whites."""
    tone = curve([(0, 0.05), (0.25, 0.32), (0.55, 0.67), (0.85, 0.915), (1, 0.985)])
    out = tone(rgb)
    out = split_tone(out, [0.006, 0.004, 0.0], [0.002, 0.002, 0.0])
    return mix_saturation(out, 0.78)


def graphite(rgb):
    """Black and white with a red-filter lean: dark skies, firm blacks, soft whites."""
    mono = rgb @ np.array([0.40, 0.48, 0.12])
    tone = curve([(0, 0.022), (0.22, 0.17), (0.55, 0.54), (0.85, 0.875), (1, 0.97)])
    y = tone(mono)
    return np.stack([y * 1.003, y, y * 0.992], axis=-1)


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
